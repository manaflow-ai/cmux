import CryptoKit
public import Foundation
import LocalAuthentication
import os
import Security

/// This Mac's long-lived identity key for iPhone links (cmux-next-ios PROTOCOL.md
/// "Mac identity"): a P-256 key the app keeps in the login Keychain and hands
/// to cmux-mobile-host over stdin (`mac_identity`, never logged). hostd proves it in
/// every `auth`; a phone pins it per Mac device id the first time it pairs and
/// refuses a host that cannot prove it later, so a host registered with a
/// stolen token cannot pass as this Mac.
public struct MobileHostMacIdentity: Sendable, Equatable {
    /// The raw 32-byte private scalar.
    public let privateKey: Data
    /// The 65-byte X9.63 public point.
    public let publicKey: Data

    public init(privateKey: Data, publicKey: Data) {
        self.privateKey = privateKey
        self.publicKey = publicKey
    }

    /// A new key.
    public static func generate() -> MobileHostMacIdentity {
        let key = P256.Signing.PrivateKey()
        return MobileHostMacIdentity(privateKey: key.rawRepresentation, publicKey: key.publicKey.x963Representation)
    }

    /// From a stored private scalar; nil for anything else.
    public static func restore(_ privateKey: Data) -> MobileHostMacIdentity? {
        guard let key = try? P256.Signing.PrivateKey(rawRepresentation: privateKey) else { return nil }
        return MobileHostMacIdentity(privateKey: key.rawRepresentation, publicKey: key.publicKey.x963Representation)
    }

    /// The first 8 bytes of the public key's SHA-256 as hex (what a phone may show).
    public var fingerprint: String { MobileHostPairedDevices.fingerprint(MobileHostMacIdentity.hex(publicKey)) }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

/// Where the identity key lives: the login Keychain (a generic password of
/// `service`, this device only), created on first use. When the Keychain
/// refuses (a build without Keychain access), a 0600 file in the iPhone host's
/// state folder holds it instead, so the key, and the phones' pins, survive.
public struct MobileHostMacIdentityStore: Sendable {
    public let service: String
    public let fallbackFile: URL
    /// Off in tests: only the file is used.
    let useKeychain: Bool

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mobile.identity")

    /// A context that fails instead of showing Keychain UI.
    private static func noPrompt() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    public init(bundleID: String, stateDirectory: URL, useKeychain: Bool = true) {
        service = bundleID + ".iphone-host.identity"
        fallbackFile = stateDirectory.appendingPathComponent("mac-identity", isDirectory: false)
        self.useKeychain = useKeychain
    }

    /// The stored key, or a new one saved now. Blocking I/O: call it off the main actor.
    /// It never shows Keychain UI: an item this build may not read without asking (a
    /// re-signed app) is skipped, with a log line, for the file store.
    public func loadOrCreate() throws -> MobileHostMacIdentity {
        if useKeychain, let stored = keychainRead().flatMap(MobileHostMacIdentity.restore) { return stored }
        if let data = try? Data(contentsOf: fallbackFile), let stored = MobileHostMacIdentity.restore(data) {
            return stored
        }
        let identity = MobileHostMacIdentity.generate()
        if !(useKeychain && keychainAdd(identity.privateKey)) {
            try writeFallback(identity.privateKey)
        }
        return identity
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "identity"]
    }

    private func keychainRead() -> Data? {
        var item: CFTypeRef?
        let search = query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
                                    kSecUseAuthenticationContext as String: Self.noPrompt()]) { $1 }
        let status = SecItemCopyMatching(search as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                Self.logger.error("iPhone host identity: Keychain read refused (\(status, privacy: .public)); using the file store")
            }
            return nil
        }
        return item as? Data
    }

    private func keychainAdd(_ privateKey: Data) -> Bool {
        let add = query.merging([kSecValueData as String: privateKey,
                                 kSecUseAuthenticationContext as String: Self.noPrompt(),
                                 kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                 kSecAttrLabel as String: "cmux iPhone host identity"]) { $1 }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private func writeFallback(_ privateKey: Data) throws {
        let directory = fallbackFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try privateKey.write(to: fallbackFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fallbackFile.path)
    }
}
