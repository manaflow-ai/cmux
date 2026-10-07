public import Foundation

/// The trusted-key questions transports ask (b6-pairing.md section 7). Every
/// answer comes from the trust store mirror with the certificate re-verified
/// locally against the install key.
public protocol TrustedKeyLookup: Sendable {
    /// The pinned `direct` key of `host` (B4's endpoint resolver, C9's direct host records).
    func hostKey(for host: String) async -> TrustedHostKey?
    /// Whether a device presenting `directKey` may connect (B4's `DirectAuthorizer`, run by
    /// the Mac in B5). With `host`, accepted guests of that host count too.
    func isTrustedDevice(directKey: Data, onHost host: String?) async -> Bool
    /// Whether `certificate` is a valid `dtls` proof by `install` (B2 compares its key with
    /// the SDP fingerprint before accepting DTLS).
    func verifyFingerprint(_ certificate: LinkCertificate, from install: String) async -> Bool
}
