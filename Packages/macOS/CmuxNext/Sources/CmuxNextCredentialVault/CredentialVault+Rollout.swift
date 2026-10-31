public import CmuxNextDesign

nonisolated extension CredentialVault {
    /// The single live rollout decision, including public API default arguments.
    public static var isRolloutEnabled: Bool { rolloutEnabled.value }

    /// Credential storage is an opt-in canary in DEV and NIGHTLY. Release keeps this off.
    /// Every app entrypoint reads this same switch; disabling stops new requests.
    public static let rolloutEnabled = Tunable<Bool>.toggle(
        "credentialVault.enabled",
        TunableSection(id: "credentialVault", title: CredentialVaultStrings.rolloutTitle, symbol: "key", order: 44),
        CredentialVaultStrings.rolloutTitle,
        help: CredentialVaultStrings.disabled,
        default: false, code: "CredentialVault.rolloutEnabled")
}
