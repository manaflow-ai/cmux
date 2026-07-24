/// The identity of an in-flight account switch.
///
/// Provider-scoped because account ids are unique only within one provider:
/// a Codex email and a Claude profile can be the same string, and only the
/// row actually being switched may show pending UI.
public struct SubrouterPendingSwitch: Sendable, Hashable {
    /// The provider whose active account is being switched.
    public let provider: SubrouterProvider
    /// The daemon account id the switch targets.
    public let accountID: String

    /// Creates a pending-switch identity.
    /// - Parameters:
    ///   - provider: The provider whose active account is being switched.
    ///   - accountID: The daemon account id the switch targets.
    public init(provider: SubrouterProvider, accountID: String) {
        self.provider = provider
        self.accountID = accountID
    }
}
