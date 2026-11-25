import Foundation

/// A snapshot of one list for one signed-in account. Keep this handle across a refresh so
/// its reply can only update the original list, and sign-out can invalidate it.
@MainActor
public struct LastKnownList {
    fileprivate let store: LastKnownListStore
    fileprivate let file: URL
    fileprivate let generation: Int

    /// A successful empty result decodes just like any other value. Only a cache miss returns nil.
    public func read<Value: Codable & Sendable>(_ type: Value.Type) -> Value? {
        guard store.generation == generation else { return nil }
        return store.read(type, at: file)
    }

    /// Call after a successful list response, including an empty one.
    public func save<Value: Codable & Sendable>(_ value: Value) {
        guard store.generation == generation else { return }
        store.save(value, at: file)
    }
}

/// Apple storage for list display data. The app's Caches directory is private, purgeable,
/// and excluded from backups. Credentials and live connections never belong in a snapshot.
@MainActor
public final class LastKnownListStore {
    public static let standard: LastKnownListStore = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return LastKnownListStore(directory: base.appending(path: "cmux-mobile-lists-v1"))
    }()

    private final class Entry {
        let value: (any Sendable)?
        init(_ value: (any Sendable)?) { self.value = value }
    }

    nonisolated private static let hex = Array("0123456789abcdef".utf8)
    private let directory: URL
    // Same ordering for atomic writes, cold reads, and sign-out deletion.
    private let io = DispatchQueue(label: "dev.cmux.mobile.last-known-lists", qos: .utility)
    private let memory = NSCache<NSURL, Entry>()
    fileprivate var generation = 0

    public init(directory: URL) {
        self.directory = directory
        memory.countLimit = 64
    }

    /// Each component identifies a different source of rows, including the absence of a team.
    public func list(accountID: String, teamID: String? = nil, screen: String, context: [String] = []) -> LastKnownList {
        let parts: [String?] = [accountID, teamID, screen] + context.map(Optional.some)
        let file = Self.scopedDirectory(in: directory, components: parts).appending(path: "rows.json")
        return LastKnownList(store: self, file: file, generation: generation)
    }

    /// A case-insensitive filesystem can preserve distinct account, team and source IDs by
    /// encoding each path component separately, including absent and empty identifiers.
    nonisolated public static func scopedDirectory(in directory: URL, components: [String?]) -> URL {
        components.reduce(directory) { url, part in
            guard let part else { return url.appending(path: "nil") }
            // Lowercase hex is reversible even on a case-insensitive file system. Split long
            // components (such as backend URLs) below the file system's filename length limit.
            let bytes = Array(part.utf8)
            return stride(from: 0, to: bytes.count, by: 100).reduce(url.appending(path: "s")) { parent, start in
                let chunk = bytes[start..<min(start + 100, bytes.count)]
                var hex: [UInt8] = []
                hex.reserveCapacity(chunk.count * 2)
                for byte in chunk {
                    hex.append(Self.hex[Int(byte >> 4)])
                    hex.append(Self.hex[Int(byte & 15)])
                }
                return parent.appending(path: String(decoding: hex, as: UTF8.self))
            }
        }
    }

    fileprivate func read<Value: Codable & Sendable>(_ type: Value.Type, at file: URL) -> Value? {
        if let entry = memory.object(forKey: file as NSURL) { return entry.value as? Value }
        // A cold first frame needs its own list before it can draw. Subsequent opens read memory.
        do {
            let value = try io.sync { try JSONDecoder().decode(type, from: Data(contentsOf: file)) }
            memory.setObject(Entry(value), forKey: file as NSURL)
            return value
        } catch CocoaError.fileReadNoSuchFile {
            memory.setObject(Entry(nil), forKey: file as NSURL)
        } catch {
            // Protected data may become readable after unlock.
        }
        return nil
    }

    fileprivate func save<Value: Codable & Sendable>(_ value: Value, at file: URL) {
        memory.setObject(Entry(value), forKey: file as NSURL)
        io.async {
            guard let data = try? JSONEncoder().encode(value) else { return }
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                // The in-memory list still works when protected storage or disk space is unavailable.
            }
        }
    }

    public func removeAll() {
        generation += 1
        memory.removeAllObjects()
        let directory = directory
        io.async { try? FileManager.default.removeItem(at: directory) }
    }

    /// Wait for pending disk writes (tests).
    func flush() { io.sync {} }
}
