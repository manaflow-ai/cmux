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
    /// Which id was made on which computer (``MachineRecord``).
    var deviceMachineFile: URL { root.appendingPathComponent("device-id.machine") }
    /// Held while a copied id is checked and replaced.
    var deviceIDLock: URL { root.appendingPathComponent("device-id.lock") }
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
    /// An id made on another computer is replaced, so a Mac that Migration Assistant or a restore copied the
    /// folder to is a new install, not a second copy of the old Mac. `device-id.machine` records which id was
    /// made on which computer (`<id> <stamp>`, ``HostMachine/stamp(purpose:)``); `device-id` itself stays one
    /// line, so an older build (a rollback) reads the same id. A record that names another id, or none (an
    /// older build's id), is not a copy: the id is kept and the record written for this computer. Without a
    /// host UUID every id is kept.
    ///
    /// The check and the replacement run under an flock on `device-id.lock` (blocking file I/O, like every
    /// call here: ``CloudDeviceID`` reads on the files lane), so concurrent first reads on the new Mac agree
    /// on one new id. The fast path (an id this computer already recorded) takes no lock.
    public func loadOrCreateDeviceID() throws -> String {
        guard let stamp = host()?.stamp(purpose: Self.machinePurpose) else { return try loadOrCreateUnstamped() }
        if let id = readDeviceID(), readMachineRecord() == MachineRecord(id: id, stamp: stamp) { return id }
        try prepare()
        let lock = open(deviceIDLock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var id = try loadOrCreateUnstamped()
        if let record = readMachineRecord(), record.id == id, record.stamp != stamp {
            // Made on another computer: this Mac is a new install.
            id = Self.newDeviceID()
            try writeSecret(id + "\n", to: deviceIDFile)
        }
        if readMachineRecord() != MachineRecord(id: id, stamp: stamp) {
            try writeSecret(MachineRecord(id: id, stamp: stamp).text, to: deviceMachineFile)
        }
        return id
    }

    /// The id in `device-id`, made when there is none (the first id written wins).
    private func loadOrCreateUnstamped() throws -> String {
        if let id = readDeviceID() { return id }
        let id = Self.newDeviceID()
        // Read before any Cloud sign-in (agent tabs' install id): the directory may not exist yet.
        try prepare()
        try createSecretIfAbsent(id + "\n", at: deviceIDFile)
        if let written = readDeviceID() { return written }
        // An empty file (a write cut short by an older build) is replaced, as before.
        try writeSecret(id + "\n", to: deviceIDFile)
        return id
    }

    static func newDeviceID() -> String { "mac-\(UUID().uuidString.lowercased())" }

    /// `device-id.machine`: which id was made on which computer.
    struct MachineRecord: Equatable {
        var id: String
        var stamp: String
        var text: String { "\(id) \(stamp)\n" }
    }

    private func readMachineRecord() -> MachineRecord? {
        guard let text = try? String(blockingContentsOf: deviceMachineFile, encoding: .utf8) else { return nil }
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2 else { return nil }
        return MachineRecord(id: String(parts[0]), stamp: String(parts[1]))
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
