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

    public init(phoneDeviceID: String, name: String, identityKey: String, approvalKey: String, registeredAt: Date? = nil) {
        self.phoneDeviceID = phoneDeviceID
        self.name = name
        self.identityKey = identityKey
        self.approvalKey = approvalKey
        self.registeredAt = registeredAt
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
/// digest in `seal` (``MobileHostPairingSealStore``).
public struct MobileHostPairedDevicesFile: Sendable {
    public let file: URL
    let seal: any MobileHostPairingSealStore

    public init(directory: URL, seal: any MobileHostPairingSealStore) {
        file = directory.appendingPathComponent("paired-devices.json", isDirectory: false)
        self.seal = seal
    }

    /// One serial queue for every list's reads and writes: they leave the caller's thread (the
    /// seal is a Keychain item, and the iPhone host calls from the main actor) and keep its order.
    /// Registered in plans/cmux-next/threading-model.md.
    private static let queue = DispatchQueue(label: "com.cmuxterm.mobile.paired-devices", qos: .utility)

    /// The digests of lists a removal replaced in this run, per file: never trusted again in this
    /// process, also when the Keychain refused to forget them and that list's exact bytes are put
    /// back. Only the Keychain outlives the process, so across a relaunch a Keychain that refuses
    /// every write of the app's own item keeps such a list trusted (logged as a fault).
    private static let withdrawn = Mutex<[String: Set<Data>]>([:])

    /// `load` on the queue, after every save queued before it.
    public func loadInBackground(userID: String) async -> MobileHostPairedDevices {
        await withCheckedContinuation { continuation in
            Self.queue.async { continuation.resume(returning: self.load(userID: userID)) }
        }
    }

    /// `save` on the queue, in the order called; a failure is logged.
    public func saveInBackground(_ devices: MobileHostPairedDevices) {
        Self.queue.async {
            do {
                try self.save(devices)
            } catch {
                Self.logger.error("paired phones not saved: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mobile.pairing")

    /// A save that takes trust away (a phone revoked or unpaired, a sign-out). It never waits on
    /// the caller's thread: on the queue, after every save queued before it, the list it replaces
    /// stops counting in this run, then `save` takes the old digest away before it writes the new
    /// list and records it. The caller's own list is the one in force from the call on. `done`
    /// (tests) gets whether the new list was written and recorded.
    public func saveRemovingTrust(_ devices: MobileHostPairedDevices, then done: (@Sendable (Bool) -> Void)? = nil) {
        Self.queue.async {
            if let old = seal.digest() { Self.withdrawn.withLock { $0[file.path, default: []].insert(old) } }
            do {
                try self.save(devices)
                done?(true)
            } catch {
                Self.logger.error("paired phones not saved: \(String(describing: error), privacy: .public)")
                done?(false)
            }
        }
    }

    /// App quit only (`applicationWillTerminate`, under its reviewed blocking allowance): waits, up
    /// to `limit`, for the saves already queued, a removal's among them.
    public static func flush(within limit: TimeInterval = 2) {
        // concurrency-allow: app quit only, inside allowBlocking(.terminate) in applicationWillTerminate; bounded by `limit` (2 s).
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        if done.blockingWait(timeout: .now() + limit) == .timedOut {
            logger.error("iPhone pairing: queued saves did not finish before quit")
        }
    }

    /// The stored list when it is the one this app saved last (its digest matches the seal's) and
    /// belongs to `userID`, else an empty one for that user. Both consumers (hostd's pinned keys,
    /// acpmux's approvers) get only this result. Any other list (changed, an older copy put back,
    /// one a build before the seal wrote, or one saved while the Keychain refused) trusts no
    /// phone: each pairs again, which the person approves.
    public func load(userID: String) -> MobileHostPairedDevices {
        guard let data = try? Data(contentsOf: file) else { return MobileHostPairedDevices(userID: userID) }
        guard let sealed = seal.digest(), sealed == MobileHostPairingSeal.digest(data),
              !Self.withdrawn.withLock({ $0[file.path]?.contains(sealed) ?? false }) else {
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
        let digest = MobileHostPairingSeal.digest(data)
        guard seal.setDigest(digest) else {
            if !seal.clearDigest() {
                Self.logger.fault("iPhone pairing: the Keychain refuses every write of the pairing seal; until it takes one, a list this app saved before can count again after a relaunch")
            }
            throw MobileHostPairingSealError.keychainRefused
        }
        // The list just recorded is the one in force, even if a removal had replaced the same bytes.
        Self.withdrawn.withLock { _ = $0[file.path]?.remove(digest) }
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
