public import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

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

    /// The approvers acpmux gets (`_acpmux/approvers_set`).
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

/// ``MobileHostPairedDevices`` in `<directory>/paired-devices.json`, mode 0600.
public struct MobileHostPairedDevicesFile: Sendable {
    public let file: URL

    public init(directory: URL) {
        file = directory.appendingPathComponent("paired-devices.json", isDirectory: false)
    }

    /// The stored list when it belongs to `userID`, else an empty one for that user.
    public func load(userID: String) -> MobileHostPairedDevices {
        guard let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode(MobileHostPairedDevices.self, from: data),
              stored.userID == userID else { return MobileHostPairedDevices(userID: userID) }
        return stored
    }

    public func save(_ devices: MobileHostPairedDevices) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(devices).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
