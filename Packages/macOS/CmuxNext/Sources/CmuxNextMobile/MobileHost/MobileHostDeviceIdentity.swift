public import Foundation
import CmuxNextCompat
import CryptoKit

/// This Mac's mobile device id for one account: a UUID in
/// `<directory>/device-id.<owner>` (the app's Application Support folder, per
/// bundle id), created on first use with mode 0600. The id is not a secret;
/// the service ties it to the user who registers it first (`403 not_owner`
/// for anyone else), so each account signed in to this build gets an id of its
/// own, the way the phone keeps one pair per account (cmux-next-ios
/// verify/persistence.md). Account A's id never reaches account B.
///
/// Beside the id, `device-id.<owner>.machine` holds the computer it was made
/// on (``machineTag(owner:hostUUID:)``, the `machineId` hostd registers). A
/// folder Migration Assistant or a restore copied to another Mac carries the
/// old Mac's tag: that copy makes a new id on first use, so two Macs never
/// register as one device and replace each other's signaling socket.
public struct MobileHostDeviceIdentity: Sendable {
    public let directory: URL
    /// The signed-in account (its Stack user id) this id belongs to.
    public let owner: String
    private let hostUUID: @Sendable () -> Data?
    private let fileManager: @Sendable () -> FileManager

    /// - Parameters:
    ///   - directory: hostd's state folder for this build.
    ///   - owner: The signed-in account's user id.
    ///   - hostUUID: This computer's 16-byte host UUID (nil when unknown: no copy check then).
    public init(directory: URL, owner: String, hostUUID: @escaping @Sendable () -> Data? = { MobileHostDeviceIdentity.currentHostUUID() },
                fileManager: @escaping @Sendable () -> FileManager = { .default }) {
        self.directory = directory
        self.owner = owner
        self.hostUUID = hostUUID
        self.fileManager = fileManager
    }

    /// The file name part for `owner`: Stack user ids are UUIDs, so the id itself; anything
    /// else (or an empty id) becomes the hex SHA-256 of it, so no owner names a path.
    static func component(of owner: String) -> String {
        let allowed = owner.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
        if !owner.isEmpty, owner.count <= 64, allowed, owner.allSatisfy(\.isASCII) { return owner }
        return SHA256.hash(data: Data(owner.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public var file: URL { directory.appendingPathComponent("device-id.\(Self.component(of: owner))", isDirectory: false) }
    /// The computer the id was made on.
    public var machineFile: URL { directory.appendingPathComponent("device-id.\(Self.component(of: owner)).machine", isDirectory: false) }
    /// The one id builds before per-account ids kept for whoever was signed in.
    public var legacyFile: URL { directory.appendingPathComponent("device-id", isDirectory: false) }

    /// The stored id, or a new one written now. Throws when the folder cannot be written.
    ///
    /// A stored id made on another computer (a copied folder) is replaced. Before per-account
    /// ids, a build kept one `device-id` for whoever registered it: the account that owns it
    /// adopts it (``adoptsLegacy()``), so its phones keep this Mac; any other account gets a new id.
    public func deviceID() throws -> String {
        let machine = hostUUID().map { Self.machineTag(owner: owner, hostUUID: $0) }
        if let id = Self.readID(file) {
            let stored = (try? String(blockingContentsOf: machineFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let machine, let stored, !stored.isEmpty, stored != machine else {
                // Same computer, or a record from before the machine check: keep it (and record this computer).
                // A failed stamp leaves the id as it is: the check runs again next time.
                if let machine, stored != machine { try? write(machine, to: machineFile) }
                return id
            }
            // Copied from another Mac: this computer is a new device.
        } else if adoptsLegacy(), let id = Self.readID(legacyFile) {
            try write(id, to: file)
            if let machine { try write(machine, to: machineFile) }
            try? fileManager().removeItem(at: legacyFile)
            return id
        }
        let id = UUID().uuidString.lowercased()
        try write(id, to: file)
        if let machine { try write(machine, to: machineFile) } else { try? fileManager().removeItem(at: machineFile) }
        return id
    }

    /// Forgets this account's id (the owner removed this Mac, or the service says another
    /// account owns it): the next ``deviceID()`` is new. Other accounts' ids stay.
    public func forget() {
        try? fileManager().removeItem(at: file)
        try? fileManager().removeItem(at: machineFile)
    }

    /// Forgets this account's id only while it is still `id`: a refusal reported for an id this
    /// account has since replaced, or for another account's hostd, forgets nothing.
    /// - Returns: whether the id was forgotten.
    @discardableResult
    public func forget(ifID id: String) -> Bool {
        guard Self.readID(file) == id.lowercased() else { return false }
        forget()
        return true
    }

    /// Whether the unkeyed `device-id` of an older build is this account's: the paired list
    /// beside it names the account that ran hostd here last, and when there is no list (no phone
    /// was ever allowed, so no phone pins this Mac) the first account takes it. If that guess is
    /// wrong the service answers `not_owner` and the id is replaced (``forget()``).
    func adoptsLegacy() -> Bool {
        guard fileManager().fileExists(atPath: legacyFile.path) else { return false }
        let list = directory.appendingPathComponent(MobileHostPairedDevicesFile.fileName, isDirectory: false)
        guard let data = try? Data(blockingContentsOf: list) else { return true }
        guard let users = MobileHostPairedDevicesFile.storedUserIDs(in: data) else { return true }
        return users.contains(owner)
    }

    /// The machine id hostd registers for `owner` on this computer (cmux-mobile-host
    /// `config::machine_id`): HMAC-SHA256 under `cmux-mobile machine-id v1` of
    /// `<owner> NUL <16-byte host UUID>`, first 16 bytes in lowercase hex. The hardware id
    /// never leaves the Mac, and two accounts get unrelated tags.
    public static func machineTag(owner: String, hostUUID: Data) -> String {
        let key = SymmetricKey(data: Data("cmux-mobile machine-id v1".utf8))
        var message = Data(owner.utf8)
        message.append(0)
        message.append(hostUUID)
        let tag = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return Data(tag).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// This computer's host UUID (`gethostuuid`, the IOPlatformUUID every build reads alike).
    public static func currentHostUUID() -> Data? {
        var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var wait = timespec(tv_sec: 1, tv_nsec: 0)
        let ok = withUnsafeMutablePointer(to: &uuid) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: 16) { gethostuuid($0, &wait) }
        } == 0
        let id = withUnsafeBytes(of: uuid) { Data($0) }
        guard ok, id.contains(where: { $0 != 0 }) else { return nil }
        return id
    }

    private static func readID(_ url: URL) -> String? {
        guard let text = try? String(blockingContentsOf: url, encoding: .utf8),
              let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return id.uuidString.lowercased()
    }

    private func write(_ text: String, to url: URL) throws {
        try fileManager().createDirectory(at: directory, withIntermediateDirectories: true,
                                          attributes: [.posixPermissions: 0o700])
        try Data(text.utf8).blockingWrite(to: url, options: .atomic)
        try fileManager().setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
