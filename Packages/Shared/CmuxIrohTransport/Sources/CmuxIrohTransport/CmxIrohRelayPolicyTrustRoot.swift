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

    /// Reads the current and staged-next public keys from an app information dictionary.
    ///
    /// The array form is authoritative so a release can overlap signing keys during
    /// rotation. The single-key form remains supported for already-shipped builds.
    public static func appPinned(
        infoDictionary: [String: Any]?
    ) -> CmxIrohRelayPolicyTrustRoot? {
        let records: [[String: String]]
        if let configured = infoDictionary?["CMUXIrohRelayPolicyTrustKeys"]
            as? [[String: String]] {
            records = configured
        } else if let keyID = infoDictionary?["CMUXIrohRelayPolicyKeyID"] as? String,
                  let publicKey = infoDictionary?["CMUXIrohRelayPolicyPublicKeyBase64"]
                    as? String {
            records = [["keyID": keyID, "publicKeyBase64": publicKey]]
        } else {
            return nil
        }
        // An unused rotation slot: a build configuration that does not stage
        // a key for a slot leaves both substitution variables undefined, and
        // the Info.plist build expands them to empty strings. Only the
        // exactly-empty pair is skipped; a partially filled or otherwise
        // invalid record still fails the whole trust root closed below.
        let activeRecords = records.filter { record in
            !(record["keyID"] == "" && record["publicKeyBase64"] == "")
        }
        let keys = activeRecords.compactMap { record -> CmxIrohRelayPolicyVerificationKey? in
            guard let keyID = record["keyID"],
                  let publicKey = record["publicKeyBase64"] else { return nil }
            return try? CmxIrohRelayPolicyVerificationKey(
                keyID: keyID,
                rawPublicKeyBase64: publicKey
            )
        }
        guard keys.count == activeRecords.count else { return nil }
        return try? CmxIrohRelayPolicyTrustRoot(keys: keys)
    }

    func key(id: String) -> CmxIrohRelayPolicyVerificationKey? {
        keys.first { $0.keyID == id }
    }
}
