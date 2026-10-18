import CmuxNextCompat
public import Foundation

/// A phone the person let use this Mac (Settings > Accounts > Phone Access).
/// Named by its cmux account device id, never by a transport address, so the
/// list survives a change of transport.
public struct PhoneDevice: Codable, Equatable, Sendable, Identifiable {
    /// The account's id for the phone (stable across connections).
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
/// phone host's state directory. Thread-safe; every change is written at once.
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
    public func allow(_ device: PhoneDevice) {
        change { list in
            if let index = list.firstIndex(where: { $0.id == device.id }) {
                list[index].name = device.name
            } else {
                list.append(device)
            }
        }
    }

    public func remove(_ id: String) {
        change { list in list.removeAll { $0.id == id } }
    }

    /// Notes that `id` connected now.
    public func touch(_ id: String, at date: Date = Date()) {
        change { list in
            if let index = list.firstIndex(where: { $0.id == id }) { list[index].lastSeenAt = date }
        }
    }

    private func change(_ edit: (inout [PhoneDevice]) -> Void) {
        let snapshot = devices.withLock { list -> [PhoneDevice] in
            edit(&list)
            return list
        }
        guard let data = try? Self.encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
