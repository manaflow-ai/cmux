import CryptoKit
public import Foundation

/// This Mac's link keys (b4-direct.md 2, b3-webrtc-wg.md 3): the X25519
/// `direct` key and the X25519 WireGuard key (WebRTC signs with the install
/// key itself, `MobileLinkHostAccount.webrtcIdentity`), made on first use and kept as 0600 files in the app's
/// state directory (one set per bundle id, like the irx host's DEBUG keys).
/// Release builds should move them to the Keychain (`ThisDeviceOnly`).
public struct MobileLinkKeyStore: Sendable {
    public enum Key: String, Sendable, CaseIterable {
        case direct = "direct-x25519"
        case wireGuard = "wg-x25519"
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The raw private key for `key`, made and stored on first use.
    public func privateKey(_ key: Key) throws -> Data {
        let url = directory.appendingPathComponent(key.rawValue)
        if let stored = try? Data(contentsOf: url), !stored.isEmpty { return stored }
        let made = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: url.path, contents: made, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return made
    }
}
