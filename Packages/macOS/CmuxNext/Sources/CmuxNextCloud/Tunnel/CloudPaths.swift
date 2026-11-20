public import CmuxNextCompat
import CryptoKit
public import Foundation

/// Per-installation Cloud state: the device id and cmux-tui link client state. Owner-only (0700
/// directories, 0600 files). Namespaced by bundle id so tagged builds do not
/// share an identity with the stable app.
public struct CloudPaths: Sendable {
    public let root: URL
    /// This computer (``HostMachine/current()``; tests inject another): a `device-id` made on another
    /// Mac and copied here (Migration Assistant, a restore) is not this Mac's.
    let host: @Sendable () -> HostMachine?

    public init(root: URL, host: @escaping @Sendable () -> HostMachine? = { HostMachine.current() }) {
        self.root = root
        self.host = host
    }

    /// `cloud-next` in the bundle's own folder under `cmux-next` (``NextSupport/bundleFolder(bundleID:)``);
    /// builds before kept it in classic cmux's `cmux/<bundle id>`, and the app moves it at launch.
    public static func standard(bundleID: String?) -> CloudPaths {
        CloudPaths(root: NextSupport().bundleFolder(bundleID: bundleID).appendingPathComponent("cloud-next", isDirectory: true))
    }

    /// Where builds before the per-launch key kept this Mac's WireGuard private key.
    var legacyPrivateKey: URL { root.appendingPathComponent("wireguard.private.key") }
    var deviceIDFile: URL { root.appendingPathComponent("device-id") }
    /// The computer `device-id` was made on (``HostMachine/stamp(purpose:)``).
    var deviceMachineFile: URL { root.appendingPathComponent("device-id.machine") }
    static let machinePurpose = "cmux cloud install machine v1"
    /// Where builds before the stdin config wrote the hub's config (with the private key).
    var legacyWireGuardConfig: URL { root.appendingPathComponent("wireguard.conf") }
    var linkState: URL { root.appendingPathComponent("link-state", isDirectory: true) }

    /// The link's local v12 socket, short enough for `sun_path`.
    func linkSocket(machineID: String) -> String {
        // Hashed by its name from before the move to `cmux-next`, so a link an older launch started keeps its socket.
        let hash = SHA256.hash(data: Data((NextSupport.pathIdentity(root.path) + machineID).utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
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
        // An earlier build's WireGuard key and config files go, so no other program can start a tunnel on this Mac's key.
        for legacy in [legacyWireGuardConfig, legacyPrivateKey] { try? FileManager.checked.removeItem(at: legacy) }
    }

    /// Writes `text` atomically with mode 0600.
    func writeSecret(_ text: String, to url: URL) throws {
        // Its own temporary name per call: two first reads writing at once never share one.
        let temporary = url.appendingPathExtension("\(UUID().uuidString).tmp")
        _ = FileManager.checked.createFile(atPath: temporary.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
        guard rename(temporary.path, url.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    /// `mac-<uuid>`, created once per installation. Blocking disk I/O: call it off the main thread.
    ///
    /// Callers that read it for the first time at once (the App's launch read on the files lane, a
    /// main-thread caller before that read ends, the tunnel hub) all return the same id: the first id
    /// written wins (``createSecretIfAbsent(_:at:)``) and every caller returns the file's id.
    ///
    /// An id made on another computer (its `device-id.machine` names another Mac: the folder came over
    /// with Migration Assistant or a restore) is set aside and a new one made, so this Mac is a new
    /// install, not a second copy of the old Mac's. An id with no record of its computer (an older
    /// build's) is kept and stamped with this one.
    public func loadOrCreateDeviceID() throws -> String {
        let stamp = host()?.stamp(purpose: Self.machinePurpose)
        if let id = readDeviceID() {
            guard let stamp, let made = readMachine(), made != stamp else {
                if let stamp, readMachine() != stamp { try? writeSecret(stamp + "\n", to: deviceMachineFile) }
                return id
            }
            return try replaceCopiedDeviceID(stamp: stamp)
        }
        if let stamp { try? prepare(); try? writeSecret(stamp + "\n", to: deviceMachineFile) }
        let id = "mac-\(UUID().uuidString.lowercased())"
        // Read before any Cloud sign-in (agent tabs' install id): the directory may not exist yet.
        try prepare()
        try createSecretIfAbsent(id + "\n", at: deviceIDFile)
        if let written = readDeviceID() { return written }
        // An empty file (a write cut short by an older build) is replaced, as before.
        try writeSecret(id + "\n", to: deviceIDFile)
        return id
    }

    /// Replaces a `device-id` another Mac made. Concurrent first reads on the new Mac agree: the copied id
    /// moves aside by one atomic rename (only one reader's rename finds it), that reader makes the new id
    /// (``createSecretIfAbsent(_:at:)``, the first id written wins), and every reader returns the file's id.
    private func replaceCopiedDeviceID(stamp: String) throws -> String {
        try prepare()
        let aside = root.appendingPathComponent("device-id.copied-\(UUID().uuidString)")
        if rename(deviceIDFile.path, aside.path) == 0 { try? FileManager.checked.removeItem(at: aside) }
        try writeSecret(stamp + "\n", to: deviceMachineFile)
        try createSecretIfAbsent("mac-\(UUID().uuidString.lowercased())\n", at: deviceIDFile)
        guard let id = readDeviceID() else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: deviceIDFile.path]) }
        return id
    }

    /// The stamp in `device-id.machine`, or nil when there is none.
    private func readMachine() -> String? {
        guard let text = try? String(blockingContentsOf: deviceMachineFile, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The ids in the `device-id` of each folder under ``root`` (`<root>/<backend namespace>`, #35284): the
    /// install ids launches that selected those backends named this Mac with. Blocking disk I/O: call it off
    /// the main thread.
    public func backendDeviceIDs() -> [String] {
        let folders = (try? FileManager.checked.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { CloudPaths(root: $0).readDeviceID() }
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
