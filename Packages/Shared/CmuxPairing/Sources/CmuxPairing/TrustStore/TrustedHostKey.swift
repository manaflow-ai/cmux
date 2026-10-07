public import Foundation

/// A host's pinned `direct` key, verified against its install key.
public struct TrustedHostKey: Hashable, Sendable {
    public var host: String
    public var install: String
    public var name: String
    public var ownerUser: String
    /// The raw 32-byte X25519 key B4 pins.
    public var directKey: Data
    public var certificate: LinkCertificate
    /// True for this account's own Mac; false for another account's host this device was accepted on.
    public var isOwnAccount: Bool

    public init(host: String, install: String, name: String, ownerUser: String, directKey: Data,
                certificate: LinkCertificate, isOwnAccount: Bool) {
        self.host = host
        self.install = install
        self.name = name
        self.ownerUser = ownerUser
        self.directKey = directKey
        self.certificate = certificate
        self.isOwnAccount = isOwnAccount
    }

    /// Standard base64, the form `DirectHostKey` and `LinkPeer.hints["direct.hostKey"]` use.
    public var directKeyBase64: String { directKey.base64EncodedString() }
}
