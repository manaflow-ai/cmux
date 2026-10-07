public import Foundation

/// The fields of a `pair/1` QR link.
public struct PairingOffer: Hashable, Sendable {
    /// 26 Crockford base32 symbols (130 bits): the credential; never logged.
    public var code: String
    public var host: String
    public var team: String
    /// base64url of the host's 32-byte `direct` X25519 key: the claim binds it.
    public var hostKey: String
    public var expiresAt: Date
    /// Untrusted display name from the link; show the name the owner returns.
    public var name: String

    public init(code: String, host: String, team: String, hostKey: String, expiresAt: Date, name: String) {
        self.code = code
        self.host = host
        self.team = team
        self.hostKey = hostKey
        self.expiresAt = expiresAt
        self.name = name
    }
}
