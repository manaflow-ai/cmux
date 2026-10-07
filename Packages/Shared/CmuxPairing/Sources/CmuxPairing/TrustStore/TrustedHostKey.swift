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
    /// The host install's P-256 key: B2 pins it for the WebRTC fingerprint binding.
    public var installKey: InstallPublicKey?
    /// The host's verified `wg` key (B3), raw 32 bytes; own Macs only.
    public var wireGuardKey: Data?

    public init(host: String, install: String, name: String, ownerUser: String, directKey: Data,
                certificate: LinkCertificate, isOwnAccount: Bool, installKey: InstallPublicKey? = nil,
                wireGuardKey: Data? = nil) {
        self.installKey = installKey
        self.wireGuardKey = wireGuardKey
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
