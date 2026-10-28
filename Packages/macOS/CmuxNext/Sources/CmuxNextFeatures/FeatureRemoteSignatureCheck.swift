public import Foundation

/// The keys a flags document's signature may verify with: the nightly's
/// content-signing key and, in a bench build only, the perf lab's test key, so
/// a bench app's kill-switch done check runs without the production key
/// (p12-perf-process.md section 3.9, R12). The verify function is the
/// updater's `ContentSignature.verify`, passed in so this target stays free
/// of the updater and of CryptoKit.
public nonisolated struct FeatureRemoteSignatureCheck: Sendable {
    /// The perf lab's test public key (raw Ed25519, base64): compiled only
    /// under `CMUX_BENCH_HOOKS`, so a shipped app trusts the content-signing
    /// key alone: `check-no-bench-hooks.sh` refuses a shipped app whose
    /// executable contains this key. The private half is
    /// `schemas/features/bench-test-signing-key.json`.
    #if CMUX_BENCH_HOOKS
    public static let benchTestPublicKey: String? = "tOVR4m5KjnfoL+4rA/GqbLNDSgK8cJV8G0noc8Atvww="
    #else
    public static let benchTestPublicKey: String? = nil
    #endif

    /// The trusted public keys (raw Ed25519, base64), the content-signing key first.
    public let publicKeys: [String]
    private let verify: @Sendable (_ data: Data, _ signature: String, _ publicKey: String) -> Bool

    /// - Parameters:
    ///   - contentSigningKey: `ContentSignature.publicKey`.
    ///   - verify: whether a base64 signature signs the data with the base64 public key (`ContentSignature.verify`).
    public init(
        contentSigningKey: String,
        verify: @escaping @Sendable (_ data: Data, _ signature: String, _ publicKey: String) -> Bool
    ) {
        publicKeys = [contentSigningKey] + (Self.benchTestPublicKey.map { [$0] } ?? [])
        self.verify = verify
    }

    /// Whether `signature` (base64, surrounding whitespace ignored) signs `data` with a trusted key.
    public func isValid(_ data: Data, signature: String) -> Bool {
        let signature = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        return publicKeys.contains { verify(data, signature, $0) }
    }
}
