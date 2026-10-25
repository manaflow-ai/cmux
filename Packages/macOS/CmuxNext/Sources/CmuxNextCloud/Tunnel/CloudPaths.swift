import CmuxNextCompat
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

    func linkDeviceFingerprint(machineID: String) -> URL {
        let hash = SHA256.hash(data: Data(machineID.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return linkState.appendingPathComponent("device-fingerprint-\(hash)")
    }

    func loadLinkDeviceFingerprint(machineID: String) -> String? {
        guard let text = try? String(contentsOf: linkDeviceFingerprint(machineID: machineID), encoding: .utf8) else { return nil }
        let fingerprint = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return fingerprint.isEmpty ? nil : fingerprint
    }

    func clearLinkDeviceFingerprint(machineID: String) {
        try? FileManager.default.removeItem(at: linkDeviceFingerprint(machineID: machineID))
    }

    /// Makes the root and link-state folders (0700). Disk I/O: off the main thread (``CloudDeviceID`` reads
    /// the install id on the files lane at launch).
    func prepare() throws {
        for directory in [root, linkState] {
            try FileManager.checked.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    /// Writes `text` atomically with mode 0600.
    func writeSecret(_ text: String, to url: URL) throws {
        let temporary = url.appendingPathExtension("tmp")
        _ = FileManager.checked.createFile(atPath: temporary.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
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

    /// `mac-<uuid>`, created once per installation. Blocking disk I/O: call it off the main thread.
    ///
    /// Callers that read it for the first time at once (the App's launch read on the files lane, a
    /// main-thread caller before that read ends, the tunnel hub) all return the same id: the first id
    /// written wins (``createSecretIfAbsent(_:at:)``) and every caller returns the file's id.
    public func loadOrCreateDeviceID() throws -> String {
        if let id = readDeviceID() { return id }
        let id = "mac-\(UUID().uuidString.lowercased())"
        // Read before any Cloud sign-in (agent tabs' install id): the directory may not exist yet.
        try prepare()
        try createSecretIfAbsent(id + "\n", at: deviceIDFile)
        if let written = readDeviceID() { return written }
        // An empty file (a write cut short by an older build) is replaced, as before.
        try writeSecret(id + "\n", to: deviceIDFile)
        return id
    }

    /// The id in `device-id`, or nil when there is no file or it is empty.
    private func readDeviceID() -> String? {
        guard let text = try? String(blockingContentsOf: deviceIDFile, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Writes `text` with mode 0600 at `url` unless a file is already there: a hard link to a complete
    /// temporary file (its own name per call), so a reader never sees a part of it and a second writer
    /// never replaces the first one's file.
    func createSecretIfAbsent(_ text: String, at url: URL) throws {
        let temporary = url.appendingPathExtension("\(UUID().uuidString).tmp")
        guard FileManager.checked.createFile(atPath: temporary.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        defer { unlink(temporary.path) }
        guard link(temporary.path, url.path) == 0 || errno == EEXIST else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}
