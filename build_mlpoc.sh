#!/bin/sh
resourceGroupName="mlpocza"
pocLocation="westeurope"
mlLocation="westeurope"
servicePrincipalName="rbmlpocspaaa"
        KeyVaultName="rbmlpockvaaa"
        dataLakeName="rbmlpocdlaaa"
            BYOKName="StorageKey"
     mlWorkspaceName="rbmlpocwsaaa"
   mlWksFriendlyName="MLPoCWS"

###################################################################
# Create Resource Group
az group create --name $resourceGroupName --location $dlLocation

###################################################################
# Create a Service Principle and assign it to the scope of the Resource Group

adSP=$(az ad sp create-for-rbac --name http://$servicePrincipalName --sdk-auth --skip-assignment -o json)
appID=$(echo $adSP | jq -r '.clientId')
appPW=$(echo $adSP | jq -r '.clientSecret')

# Assign the Service Principle access to the Resource Group
rgID=$(az group show --name $resourceGroupName --query "id" --output tsv)
az role assignment create --assignee $appID --scope $rgID --role Contributor

###################################################################
# Create a keyvault for the datalake
az keyvault create \
        --name $KeyVaultName \
        --resource-group $resourceGroupName\
        --location $pocLocation \
        --sku premium \
        --enable-soft-delete true \
        --enable-purge-protection true

# Store the Service Principal ID and PW into the keyvault
az keyvault secret set --vault-name $KeyVaultName --name "spID" --value $appID
az keyvault secret set --vault-name $KeyVaultName --name "spPW" --value $appPW

# Create a Key for the Storage Account encryption
az keyvault key create \
        --name $BYOKName \
        --vault-name $KeyVaultName \
        --kty RSA \
        --ops encrypt decrypt wrapKey unwrapKey sign verify \
        --protection hsm \
        --size 2048 \
        -o json

###################################################################
# Create the Storage Account including the new identity associated with it
az storage account create \
    --resource-group $resourceGroupName\
    --name $dataLakeName \
    --kind StorageV2 \
    --sku Standard_LRS \
    --enable-large-file-share \
    --enable-hierarchical-namespace true \
    --encryption-services table queue blob file \
    --assign-identity
    
# Now we have to assign this identity access to the vault
dlID=$(az storage account show -n $dataLakeName -g $resourceGroupName --query identity.principalId -o tsv)
az keyvault set-policy \
        --name $KeyVaultName \
        --object-id $dlID \
        --key-permissions get wrapkey unwrapkey

# Configure the Storage account to use the Key we created to encrypt
kvUri=$(az keyvault show --name $KeyVaultName -o json --query properties.vaultUri -o tsv)
keyVersion=$(basename $(az keyvault key list-versions --vault-name $KeyVaultName --name $BYOKName -o tsv --query [0].kid))
az storage account update \
        --name $dataLakeName \
        --resource-group $resourceGroupName\
        --encryption-key-name $BYOKName \
        --encryption-key-source Microsoft.KeyVault \
        --encryption-key-vault $kvUri \
        --encryption-key-version $keyVersion \
        --encryption-services blob file queue table


###################################################################
# Create the ML Services Workspace - this can be in a different region

az ml workspace create \
        --workspace-name $mlWorkspaceName \
        --resource-group $resourceGroupName \
        --location $mlLocation \
        --friendly-name $mlWksFriendlyName \
        --sku enterprise

