/// Immutable public keys pinned by the app for relay-policy verification.
public struct CmxIrohRelayPolicyTrustRoot: Equatable, Sendable {
    /// The current and staged-next keys accepted during rotation.
    public let keys: [CmxIrohRelayPolicyVerificationKey]

    /// Creates a bounded relay-policy trust root.
    ///
    /// A release may pin a current key and staged replacements. Routine policy
    /// changes therefore do not pin relay URLs or require an app update.
    ///
    /// - Parameter keys: Between one and four unique Ed25519 verification keys.
    /// - Throws: ``CmxIrohRelayPolicyError/invalidTrustRoot`` for an invalid set.
    public init(keys: [CmxIrohRelayPolicyVerificationKey]) throws {
        guard (1 ... 4).contains(keys.count),
              Set(keys.map(\.keyID)).count == keys.count else {
            throw CmxIrohRelayPolicyError.invalidTrustRoot
        }
        self.keys = keys
    }

    func key(id: String) -> CmxIrohRelayPolicyVerificationKey? {
        keys.first { $0.keyID == id }
    }
}
