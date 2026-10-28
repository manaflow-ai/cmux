import CryptoKit
public import Foundation
import CmuxNextCompat

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

    func prepare() throws {
        for directory in [root, linkState] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    /// Writes `text` atomically with mode 0600.
    func writeSecret(_ text: String, to url: URL) throws {
        let temporary = url.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: temporary.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
        guard blockingRename(temporary.path, url.path) == 0 else {
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
    public func loadOrCreateDeviceID() throws -> String {
        if let text = try? String(contentsOf: deviceIDFile, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let id = "mac-\(UUID().uuidString.lowercased())"
        // Read before any Cloud sign-in (agent tabs' install id): the directory may not exist yet.
        try prepare()
        try writeSecret(id + "\n", to: deviceIDFile)
        return id
    }

    /// ``loadOrCreateDeviceID()`` as a value a launch read gives the main thread (p08-startup-076). It blocks:
    /// run it on a `BackgroundWork` files lane.
    public func deviceIDResult() -> Result<String, CloudDeviceIDError> {
        do {
            return .success(try loadOrCreateDeviceID())
        } catch {
            return .failure(.unwritable(String(describing: error)))
        }
    }
}

/// Why this Mac's install id (`device-id`) is not known.
public enum CloudDeviceIDError: Error, Equatable, Sendable {
    /// Its launch read has not ended yet (or quit dropped it): the main thread never reads the file itself.
    case notReadYet
    /// There was no id and a new one could not be written; the file error's description.
    case unwritable(String)
}

/// This Mac's install id as the launch's read of it has it (p08-startup-076): `main` reads (or makes) `device-id` on a
/// launch lane with ``CloudPaths/deviceIDResult()``, and the main thread asks this, which never touches the disk.
///
/// ```swift
/// let read = LaunchRead(in: sequence, dropped: .failure(.notReadYet)) { paths.deviceIDResult() }  // main()
/// let source = CloudDeviceIDSource(paths: paths) { read.value }
/// let id = source.result(for: paths)?.get()                                                     // never waits
/// ```
public nonisolated struct CloudDeviceIDSource: Sendable {
    /// The Cloud state whose id the read reads.
    public let paths: CloudPaths
    private let ended: @Sendable () -> Result<String, CloudDeviceIDError>?

    /// - Parameters:
    ///   - paths: The Cloud state whose id the read reads.
    ///   - ended: The read's result once it ended, else nil; it must not block.
    public init(paths: CloudPaths, ended: @escaping @Sendable () -> Result<String, CloudDeviceIDError>?) {
        self.paths = paths
        self.ended = ended
    }

    /// The id of `paths` as the read has it: ``CloudDeviceIDError/notReadYet`` while it runs; nil when the read is
    /// of other paths (the caller reads its own).
    public func result(for paths: CloudPaths) -> Result<String, CloudDeviceIDError>? {
        guard paths.root == self.paths.root else { return nil }
        return ended() ?? .failure(.notReadYet)
    }
}
