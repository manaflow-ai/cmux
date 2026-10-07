import Foundation

/// One device in the account's trust store (B6 owns it in `UserDO`; the Mac
/// holds a read-only mirror).
public struct PairedDevice: Hashable, Sendable {
    public var install: String
    /// The account user the device was paired under.
    public var userID: String
    public var keyID: String
    /// P-256 public key, x9.63 or raw.
    public var publicKey: Data
    public var displayName: String?
    public var revoked: Bool

    public init(install: String, userID: String, keyID: String, publicKey: Data, displayName: String? = nil,
                revoked: Bool = false) {
        self.install = install
        self.userID = userID
        self.keyID = keyID
        self.publicKey = publicKey
        self.displayName = displayName
        self.revoked = revoked
    }
}
