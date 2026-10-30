public import Foundation
import CmuxNextCompat
import CryptoKit
import os

/// A phone that proved its keys to `cmux-mobile-host` and asks this Mac to trust it
/// (cmux-next-ios `verify/phone-approvals.md`). The keys are 65-byte X9.63 P-256
/// points as lowercase hex: the identity key signs each link's challenge, the
/// approval key signs agent allows after Face ID.
public struct MobileHostPairRequest: Sendable, Equatable, Hashable {
    /// The phone's link device id, as the backend stamped its signals.
    public var phoneDeviceID: String
    /// The phone's own name for itself (at most 64 characters, no controls).
    public var name: String
    public var identityKey: String
    public var approvalKey: String
    /// When the backend registered the phone's device (hostd's `registered_at_ms`), shown in
    /// the prompt so a device made minutes ago stands out; nil from an older hostd.
    public var registeredAt: Date?
    /// The pre-approval the phone presented from this Mac's pairing code (``MobileHostPairTokens``),
    /// nil without one. A secret: never logged, never kept with a waiting request.
    public var pairToken: String?

    public init(phoneDeviceID: String, name: String, identityKey: String, approvalKey: String, registeredAt: Date? = nil,
                pairToken: String? = nil) {
        self.phoneDeviceID = phoneDeviceID
        self.name = name
        self.identityKey = identityKey
        self.approvalKey = approvalKey
        self.registeredAt = registeredAt
        self.pairToken = pairToken
    }

    /// The same device asking with the same keys (a retry, whatever its registration date).
    public func sameKeys(as other: MobileHostPairRequest) -> Bool {
        phoneDeviceID == other.phoneDeviceID && identityKey == other.identityKey && approvalKey == other.approvalKey
    }
}

/// One phone the user allowed on this Mac.
public struct MobileHostPairedDevice: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var identityKey: String
    public var approvalKey: String
    public var pairedAt: Date

    public init(id: String, name: String, identityKey: String, approvalKey: String, pairedAt: Date) {
        self.id = id
        self.name = name
        self.identityKey = identityKey
        self.approvalKey = approvalKey
        self.pairedAt = pairedAt
    }

    /// The first 8 bytes of the approval key's SHA-256 as hex, as acpmux lists it.
    public var fingerprint: String { MobileHostPairedDevices.fingerprint(approvalKey) }
}

/// The phones this Mac trusts for one signed-in user, and the requests the
/// user refused. A pure value: ``MobileHostPairedDevicesFile`` stores it (0600) and
/// the iPhone host hands it to hostd (links) and acpmux (approvals).
public struct MobileHostPairedDevices: Sendable, Equatable, Codable {
    /// A refused request: that device id with that identity key never asks again.
    public struct Denied: Sendable, Equatable, Codable {
        public var id: String
        public var identityKey: String
    }

    /// What to do with a request.
    public enum Decision: Sendable, Equatable {
        /// Already allowed with these keys.
        case trusted
        /// The user refused these keys before.
        case denied
        /// Ask the user.
        case ask
    }

    /// The user the list belongs to; another user starts empty.
    public var userID: String
    public private(set) var devices: [MobileHostPairedDevice] = []
    public private(set) var denied: [Denied] = []

    public init(userID: String) {
        self.userID = userID
    }

    public func decision(for request: MobileHostPairRequest) -> Decision {
        if devices.contains(where: {
            $0.id == request.phoneDeviceID && $0.identityKey == request.identityKey && $0.approvalKey == request.approvalKey
        }) { return .trusted }
        if denied.contains(where: { $0.id == request.phoneDeviceID && $0.identityKey == request.identityKey }) { return .denied }
        return .ask
    }

    /// The user allowed the request: its keys replace any older keys of that device.
    public mutating func approve(_ request: MobileHostPairRequest, at date: Date) {
        devices.removeAll { $0.id == request.phoneDeviceID }
        denied.removeAll { $0.id == request.phoneDeviceID }
        devices.append(MobileHostPairedDevice(id: request.phoneDeviceID, name: request.name, identityKey: request.identityKey,
                                       approvalKey: request.approvalKey, pairedAt: date))
    }

    /// The user refused the request.
    public mutating func deny(_ request: MobileHostPairRequest) {
        denied.removeAll { $0.id == request.phoneDeviceID }
        denied.append(Denied(id: request.phoneDeviceID, identityKey: request.identityKey))
        // Keep the newest refusals only; each refused key costs a prompt anyway.
        if denied.count > 64 { denied.removeFirst(denied.count - 64) }
    }

    /// Removed in Settings, or the phone signed out. Its keys stop working at once.
    public mutating func remove(_ id: String) {
        devices.removeAll { $0.id == id }
    }

    /// The acpmux pairing name of phone `id`'s own credential (acpmux role `phone`): what
    /// Settings > Devices joins the phone's row to for its Full-access setting
    /// (`DeviceDirectory.phoneRecordName`, kept equal by a test).
    public static func acpmuxRecordName(_ id: String) -> String {
        "phone-" + String(id.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(74))
    }

    /// The approvers acpmux gets (`_acpmux/approvers_set`).
    /// The pairing of `phone`, a phone of the account, if it is paired here (by its link id).
    public func pairing(of phone: MobileHostKnownPhone) -> MobileHostPairedDevice? {
        devices.first { phone.owns($0.id) }
    }

    /// The paired phones (link ids) that are among the account's `phones`: only these get an
    /// acpmux credential, so a phone removed from the account while this Mac was not running
    /// (still paired here, with no row in Settings > Devices) never holds Full access.
    public func listed(in phones: [MobileHostKnownPhone]) -> Set<String> {
        Set(devices.map(\.id).filter { id in phones.contains { $0.owns(id) } })
    }

    public func approversParams(macDevice: String) -> [String: Any] {
        ["macDevice": macDevice,
         "approvers": devices.map { ["id": $0.id, "publicKey": $0.approvalKey, "name": $0.name] }]
    }

    /// Lowercase or uppercase hex; nil for anything else.
    static func bytes(hex: String) -> Data? {
        var out = Data(capacity: hex.utf8.count / 2)
        var high: UInt8?
        for character in hex.utf8 {
            guard let nibble = nibble(character) else { return nil }
            if let first = high {
                out.append(first << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        return high == nil ? out : nil
    }

    private static func nibble(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): character - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    /// The first 8 bytes of a key's SHA-256 as hex (``MobileHostPairedDevice/fingerprint``).
    public static func fingerprint(_ keyHex: String) -> String {
        return SHA256.hash(data: bytes(hex: keyHex) ?? Data()).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// ``MobileHostPairedDevices`` in `<directory>/paired-devices.json`, mode 0600, sealed by its
/// digest in `seal` (``MobileHostPairingSealStore``). The iPhone host owns one per state directory, so
/// its reads, saves and this run's record of the list in force are those of one file.
public final class MobileHostPairedDevicesFile: Sendable {
    public static let fileName = "paired-devices.json"
    public let file: URL
    let seal: any MobileHostPairingSealStore
    /// Saves and withdrawals queued or running.
    private let saving = Mutex(0)
    /// Written by a quit deadline that cut off a save (``markCutOffIfSaving()``), beside the file.
    let cutOffMarker: URL
    /// Whether this file object cleared the seal for a cut-off save (``sealClearedForCutOff()``).
    private let clearedForCutOff = Mutex(false)
    /// Writes the cut-off marker (tests inject a disk that refuses it).
    private let writeMarker: @Sendable (URL) throws -> Void
    /// Told once the cut-off fact is safe without the quit's record (the marker is on disk, or the seal
    /// is cleared): the record may stop naming this file.
    private let cutOffSettled: @Sendable () -> Void

    /// Before any read or save it queues (the first item on the file's queue), a save the last quit cut
    /// off makes the stored list stop counting (``distrustIfCutOff(recorded:)``).
    ///
    /// - Parameters:
    ///   - lastQuitCutOff: Whether the last quit's record names this file as cut off (asked on the
    ///     file's queue): it fails closed also when its marker could not be written.
    ///   - cutOffSettled: Told once a cut-off save's fact is safe without the record.
    ///   - writeMarker: Writes the marker at a quit deadline (nil: an atomic empty file).
    public init(directory: URL, seal: any MobileHostPairingSealStore, lastQuitCutOff: @escaping @Sendable () -> Bool = { false },
                cutOffSettled: @escaping @Sendable () -> Void = {}, writeMarker: (@Sendable (URL) throws -> Void)? = nil) {
        file = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        cutOffMarker = directory.appendingPathComponent("paired-devices.cut-off", isDirectory: false)
        self.seal = seal
        self.cutOffSettled = cutOffSettled
        self.writeMarker = writeMarker ?? { try Data().blockingWrite(to: $0, options: .atomic) }
        queue.async { [self] in distrustIfCutOff(recorded: lastQuitCutOff()) }
    }

    /// One serial queue for the list's reads and writes: they leave the caller's thread (the
    /// seal is a Keychain item, and the iPhone host calls from the main actor) and keep its order.
    /// Registered in plans/cmux-next/threading-model.md.
    private let queue = DispatchQueue(label: "com.cmuxterm.mobile.paired-devices", qos: .utility)

    /// The digest of the newest list this run saved (nil: none yet): in this run only that list counts,
    /// so no list a later save replaced (a phone removed, a phone's keys replaced) is trusted again,
    /// also when the Keychain refused to forget its digest and its exact bytes are put back. Empty
    /// after ``withdrawTrust()``: no list counts until the next save. One digest, however
    /// many saves a run makes. Only the Keychain outlives the process, so across a relaunch (a new
    /// file object) a Keychain that refuses every write of the app's own item keeps the last list it
    /// recorded trusted (logged as a fault).
    private let inForce = Mutex<Data?>(nil)

    /// `load` on the queue, after every save queued before it.
    public func loadInBackground(userID: String) async -> MobileHostPairedDevices {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.load(userID: userID)) }
        }
    }

    /// `save` on the queue, in the order called; it never waits on the caller's thread, and the
    /// caller's list is the one in force from the call on. A failure is logged. `done` (tests) gets
    /// whether the new list was written and recorded.
    public func saveInBackground(_ devices: MobileHostPairedDevices, then done: (@Sendable (Bool) -> Void)? = nil) {
        saving.withLock { $0 += 1 }
        queue.async {
            defer { self.saving.withLock { $0 -= 1 } }
            do {
                try self.save(devices)
                done?(true)
            } catch {
                Self.logger.error("paired phones not saved: \(String(describing: error), privacy: .public)")
                done?(false)
            }
        }
    }

    /// A phone was forgotten while the list is read (its new list is saved once the read is back):
    /// on the queue, right after the read, the stored list stops counting, in this run and in the
    /// Keychain, so a quit's flush (or a crash) after this turn trusts no list with that phone.
    public func withdrawTrust() {
        saving.withLock { $0 += 1 }
        queue.async { [self] in
            defer { saving.withLock { $0 -= 1 } }
            inForce.withLock { $0 = Data() }
            if !seal.clearDigest(), !seal.clearDigest() {
                Self.logger.fault("iPhone pairing: the Keychain refuses to clear the pairing seal; until it takes a write, the stored list can count again after a relaunch")
            }
        }
    }

    /// Whether a save or a withdrawal is queued or running.
    public var isSaving: Bool {
        saving.withLock { $0 > 0 }
    }

    /// What a quit deadline found for this file (``markCutOffIfSaving()``).
    public enum CutOff: Sendable, Equatable {
        /// No save was in flight.
        case notSaving
        /// A save was cut off, and the marker is on disk.
        case marked
        /// A save was cut off, and the marker could not be written (a fault): only the quit's record
        /// names it, which the next launch also checks.
        case unmarked
    }

    /// A quit deadline's end, on its own thread, while a save may be cut off (a removal among them):
    /// when one is queued or running, it writes the cut-off marker. It never calls the Keychain (a hung
    /// securityd must not hold the process's end): the next launch clears the seal (``distrustIfCutOff(recorded:)``).
    public func markCutOffIfSaving() -> CutOff { .notSaving }

    /// On the file's queue, first: when the last quit cut off a save (its marker, or its record:
    /// `recorded`), no stored list counts in this run, and the seal is cleared, so after it the stored
    /// list no longer matches its seal and every phone pairs again (the digest rule of ``load(userID:)``).
    ///
    /// The fact must outlive this launch until the clear is done: the quit's record keeps naming the
    /// file until ``cutOffSettled`` is told, which happens once the marker is on disk (written now, before
    /// the clear, when only the record named the save) or the seal is cleared. The clear counts as a save
    /// in flight, so a quit deadline during a hung clear names the file again (``markCutOffIfSaving()``).
    /// A Keychain that refuses the clear keeps the list refused for this run, and the marker (or, when
    /// none could be written, the record) for the next launch (a fault).
    private func distrustIfCutOff(recorded: Bool) {}

    /// Whether this launch cleared the seal for a save the last quit cut off (its notice says so).
    public func sealClearedForCutOff() async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            queue.async { [self] in done.resume(returning: clearedForCutOff.withLock { $0 }) }
        }
    }

    /// How many digests this run remembers for this file (tests).
    func rememberedDigests() -> Int {
        inForce.withLock { $0 == nil ? 0 : 1 }
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mobile.pairing")

    /// The app's quit: returns, holding no thread, once the saves already queued ran, a removal's among
    /// them. No limit of its own: the quit awaits it after its deadline is armed.
    public func drained() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
    }

    /// The stored list when it is the one this app saved last (its digest matches the seal's) and
    /// belongs to `userID`, else an empty one for that user. Both consumers (hostd's pinned keys,
    /// acpmux's approvers) get only this result. Any other list (changed, an older copy put back,
    /// one a build before the seal wrote, or one saved while the Keychain refused) trusts no
    /// phone: each pairs again, which the person approves.
    public func load(userID: String) -> MobileHostPairedDevices {
        guard let data = try? Data(contentsOf: file) else { return MobileHostPairedDevices(userID: userID) }
        guard let sealed = seal.digest(), sealed == MobileHostPairingSeal.digest(data),
              inForce.withLock({ $0.map { $0 == sealed } ?? true }) else {
            Self.logger.error("iPhone pairing: paired-devices.json is not the list this app saved; no phone is trusted until it pairs again")
            return MobileHostPairedDevices(userID: userID)
        }
        guard let stored = try? JSONDecoder().decode(MobileHostPairedDevices.self, from: data),
              stored.userID == userID else { return MobileHostPairedDevices(userID: userID) }
        return stored
    }

    public func save(_ devices: MobileHostPairedDevices) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(devices)
        let digest = MobileHostPairingSeal.digest(data)
        // From here on only this list counts in this run, whatever the Keychain does below.
        inForce.withLock { $0 = digest }
        // The old digest goes first: until the new one is recorded no copy of any list counts, so a
        // crash, or a Keychain that refuses the new digest (logged there), trusts nothing, never an
        // older list put back. The new list is written even when the Keychain keeps the old digest:
        // it does not match it, so the list before it (perhaps with a phone just removed) stops
        // counting too; only that list's exact bytes put back would match again.
        // A refused clear is tried once more before the write, and again after a refused record.
        if !seal.clearDigest(), !seal.clearDigest() {
            Self.logger.error("iPhone pairing: the old digest could not be cleared")
        }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        guard seal.setDigest(digest) else {
            if !seal.clearDigest() {
                Self.logger.fault("iPhone pairing: the Keychain refuses every write of the pairing seal; until it takes one, a list this app saved before can count again after a relaunch")
            }
            throw MobileHostPairingSealError.keychainRefused
        }
    }
}

/// The paired list's read while it is in flight (the iPhone host reads it off the main actor):
/// only the newest read counts (a sign-out and sign-in of the same user meanwhile start a new one),
/// and a phone forgotten while it runs (signed out on the phone, removed in Settings) is removed
/// from the list once it is in.
public struct MobileHostPairedLoad: Sendable {
    private var generation = 0
    /// The user whose list is being read; nil when none is.
    public private(set) var userID: String?
    private var forgotten: Set<String> = []

    public init() {}

    /// A new read for `userID` (nil: no account, no read): every earlier read no longer counts.
    public mutating func begin(userID: String?) -> Int {
        generation += 1
        self.userID = userID
        forgotten = []
        return generation
    }

    /// Phone `id` was forgotten while the list is read.
    public mutating func forget(_ id: String) {
        if userID != nil { forgotten.insert(id) }
    }

    /// Read `generation` of `userID`'s list answered `list`: nil when a newer read began since,
    /// else the list without the phones forgotten meanwhile, and whether any phone was forgotten
    /// (then the list is saved as a removal, even when it never had that phone: an empty or
    /// untrusted read leaves the old digest, which must still go).
    public mutating func finish(_ generation: Int, userID: String, list: MobileHostPairedDevices) -> (list: MobileHostPairedDevices, forgot: Bool)? {
        guard generation == self.generation, self.userID == userID else { return nil }
        self.userID = nil
        var trimmed = list
        for id in forgotten { trimmed.remove(id) }
        let forgot = !forgotten.isEmpty
        forgotten = []
        return (trimmed, forgot)
    }
}

/// The iPhone host's paired-phones file as a quit deadline sees it, from any thread: the host sets it
/// on the main actor whenever its file changes, and the deadline's end asks it to mark a cut-off save.
public final class MobileHostPairedQuitWatch: Sendable {
    private let file = Mutex<MobileHostPairedDevicesFile?>(nil)

    public init() {}

    public func watch(_ file: MobileHostPairedDevicesFile?) {
        self.file.withLock { $0 = file }
    }

    /// At a quit deadline: the names for the quit's record when a save of the file is cut off
    /// (``MobileHostPairedDevicesFile/markCutOffIfSaving()``): its name, and a note when its marker
    /// could not be written.
    public func markCutOffIfSaving() -> [String] {
        switch file.withLock({ $0 })?.markCutOffIfSaving() ?? .notSaving {
        case .notSaving: []
        case .marked: [MobileHostPairedDevicesFile.fileName]
        case .unmarked: [MobileHostPairedDevicesFile.fileName, Self.unmarkedNote]
        }
    }

    /// The record's note for a cut-off save whose marker was not written.
    public static let unmarkedNote = "paired-devices.cut-off (not written)"
}
