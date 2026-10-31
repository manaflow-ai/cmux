public import CmuxNextDesign

nonisolated extension CredentialVault {
    /// Credential storage is an opt-in canary in DEV and NIGHTLY. Release keeps this off.
    /// Every app entrypoint reads this same switch; disabling stops new requests.
    public static let rolloutEnabled = Tunable<Bool>.toggle(
        "credentialVault.enabled",
        TunableSection(id: "credentialVault", title: CredentialVaultStrings.rolloutTitle, symbol: "key", order: 44),
        CredentialVaultStrings.rolloutTitle,
        help: CredentialVaultStrings.disabled,
        default: false, code: "CredentialVault.rolloutEnabled")
}
