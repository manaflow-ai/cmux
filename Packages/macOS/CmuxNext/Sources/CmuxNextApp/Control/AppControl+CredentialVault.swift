import CmuxNextControl

// `vault.*` (CredentialVaultControl): the app's vault, and its secure entry sheet on the active window.
extension AppControl {
    func registerCredentialVaultMethods(_ services: AppServices) {
        let vault = services.credentialVault
        service?.router.register(CredentialVaultControl.methods(vault: { vault }, ask: { [weak services] request in
            guard let services else { return nil }
            return await CredentialVaultEntrySheet.ask(request, services: services)
        }))
    }
}
