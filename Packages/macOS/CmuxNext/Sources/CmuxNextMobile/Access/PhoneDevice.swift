import CmuxNextCompat
public import Foundation

/// A phone the person let use this Mac (Settings > Accounts > Phone Access).
/// Named by the phone's connection key (its endpoint identity), which the
/// account cannot reassign to another device.
public struct PhoneDevice: Codable, Equatable, Sendable, Identifiable {
    /// The phone's endpoint key, lowercase hex (stable across connections).
    public var id: String
    /// The name the phone registered with the account ("Leo's iPhone").
    public var name: String
    public var approvedAt: Date
    public var lastSeenAt: Date?

    public init(id: String, name: String, approvedAt: Date = Date(), lastSeenAt: Date? = nil) {
        self.id = id
        self.name = name
        self.approvedAt = approvedAt
        self.lastSeenAt = lastSeenAt
    }
}

/// The phones allowed on this Mac, kept in one JSON file (0600) under the
/// phone host's state directory. Thread-safe; a change counts only once it is written.
public final class PhoneDeviceStore: Sendable {
    private let url: URL
    private let devices: Mutex<[PhoneDevice]>

    public init(directory: URL) {
        url = directory.appendingPathComponent("phone-access", isDirectory: true).appendingPathComponent("devices.json")
        let data = try? Data(contentsOf: url)
        devices = Mutex(data.flatMap { try? Self.decoder.decode([PhoneDevice].self, from: $0) } ?? [])
    }

    public var all: [PhoneDevice] { devices.withLock { $0 } }

    public func contains(_ id: String) -> Bool { devices.withLock { list in list.contains { $0.id == id } } }

    /// Adds `device`, or renames it and keeps its approval when it is already allowed.
    public func allow(_ device: PhoneDevice) throws {
        try change { list in
            guard list.contains(where: { $0.id == device.id }) else { return list.append(device) }
            list = list.map { known in
                var renamed = known
                if known.id == device.id { renamed.name = device.name }
                return renamed
            }
        }
    }

    /// Takes `id` off the list. A failed write keeps it listed (and allowed) and throws.
    public func remove(_ id: String) throws {
        try change { list in list.removeAll { $0.id == id } }
    }

    /// Notes that `id` connected now.
    public func touch(_ id: String, at date: Date = Date()) throws {
        try change { list in
            list = list.map { known in
                var seen = known
                if known.id == id { seen.lastSeenAt = date }
                return seen
            }
        }
    }

    /// Applies `edit` only once the new list is on disk: written to a temporary file created 0600
    /// in a 0700 folder, then renamed over the old one.
    private func change(_ edit: (inout [PhoneDevice]) -> Void) throws {
        try devices.withLock { list in
            var next = list
            edit(&next)
            try write(next)
            list = next
        }
    }

    private func write(_ list: [PhoneDevice]) throws {
        let manager = FileManager.default
        let folder = url.deletingLastPathComponent()
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let temporary = folder.appendingPathComponent(".devices-\(UUID().uuidString).json")
        guard manager.createFile(atPath: temporary.path, contents: try Self.encoder.encode(list),
                                 attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        guard rename(temporary.path, url.path) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
