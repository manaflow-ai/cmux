public import Foundation

/// Makes link key certificates for this install (b6-pairing.md section 2).
public struct LinkCertificateIssuer: Sendable {
    public let environment: String
    public let user: String
    public let install: String
    private let signer: any LinkKeySigning

    public init(environment: String, user: String, install: String, signer: any LinkKeySigning) {
        self.environment = environment
        self.user = user
        self.install = install
        self.signer = signer
    }

    /// Signs `key` (32 bytes) for `purpose`, valid from `now` for `lifetime`
    /// milliseconds (capped at the purpose's maximum).
    public func issue(purpose: LinkPurpose, key: Data, now: Date = Date(), lifetime: Int64? = nil) async throws -> LinkCertificate {
        precondition(key.count == 32, "link keys and fingerprints are 32 bytes")
        let issued = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        let expires = issued + min(lifetime ?? purpose.maxLifetimeMilliseconds, purpose.maxLifetimeMilliseconds)
        let encoded = key.base64URLEncodedString()
        let message = LinkCertificate.signedMessage(environment: environment, purpose: purpose, user: user, install: install,
                                                    key: encoded, issuedAt: issued, expiresAt: expires)
        let signature = try await signer.sign(message)
        return LinkCertificate(purpose: purpose, user: user, install: install, key: encoded, issuedAt: issued,
                               expiresAt: expires, signature: signature.base64URLEncodedString())
    }
}
