import CryptoKit
public import Foundation

/// Per-installation Cloud state: the WireGuard key, device id, completed
/// config, hub socket, and cmux-tui link client state. Owner-only (0700
/// directories, 0600 files). Namespaced by bundle id so tagged builds do not
/// share a WireGuard identity with the stable app (one key = one live
/// session).
public struct CloudPaths: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static func standard(bundleID: String?) -> CloudPaths {
        CloudPaths(root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/cmux", isDirectory: true)
            .appendingPathComponent(bundleID ?? "cmux", isDirectory: true)
            .appendingPathComponent("cloud-next", isDirectory: true))
    }

    var privateKey: URL { root.appendingPathComponent("wireguard.private.key") }
    var deviceIDFile: URL { root.appendingPathComponent("device-id") }
    var wireGuardConfig: URL { root.appendingPathComponent("wireguard.conf") }
    var linkState: URL { root.appendingPathComponent("link-state", isDirectory: true) }

    /// Unix socket paths are limited to 104 bytes; the hub socket lives in
    /// the per-user temporary directory under a short name.
    var hubSocket: String {
        let hash = SHA256.hash(data: Data(root.path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("cmux-wg-\(hash)-\(getpid()).sock")
    }

    /// The link's local v12 socket, short enough for `sun_path`.
    func linkSocket(machineID: String) -> String {
        let hash = SHA256.hash(data: Data((root.path + machineID).utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("cmux-link-\(hash).sock")
    }

    func prepare() throws {
        for directory in [root, linkState] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    /// Writes `text` atomically with mode 0600.
    func writeSecret(_ text: String, to url: URL) throws {
        let temporary = url.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: temporary.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
        guard rename(temporary.path, url.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    /// The installation's WireGuard key (Curve25519, base64 raw bytes),
    /// created once.
    func loadOrCreateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        if let text = try? String(contentsOf: privateKey, encoding: .utf8),
           let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try writeSecret(key.rawRepresentation.base64EncodedString(), to: privateKey)
        return key
    }

    /// `mac-<uuid>`, created once per installation.
    func loadOrCreateDeviceID() throws -> String {
        if let text = try? String(contentsOf: deviceIDFile, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let id = "mac-\(UUID().uuidString.lowercased())"
        try writeSecret(id + "\n", to: deviceIDFile)
        return id
    }
}
