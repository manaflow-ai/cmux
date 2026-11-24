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
    public static let standard = LastKnownListStore(directory: URL.cachesDirectory.appending(path: "cmux-mobile-lists-v1"))

    private let directory: URL
    // Same ordering for atomic writes, cold reads, and sign-out deletion.
    private let io = DispatchQueue(label: "dev.cmux.mobile.last-known-lists", qos: .utility)
    private let memory = NSCache<NSURL, AnyObject>()
    fileprivate var generation = 0

    public init(directory: URL) {
        self.directory = directory
        memory.countLimit = 64
    }

    /// Each component identifies a different source of rows, including the absence of a team.
    public func list(accountID: String, teamID: String? = nil, screen: String, context: [String] = []) -> LastKnownList {
        let parts: [String?] = [accountID, teamID, screen] + context.map(Optional.some)
        let file = parts.reduce(directory) { url, part in
            guard let part else { return url.appending(path: "nil") }
            // Lowercase hex is reversible even on a case-insensitive file system. Split long
            // components (such as backend URLs) below the file system's filename length limit.
            let bytes = Array(part.utf8)
            return stride(from: 0, to: bytes.count, by: 100).reduce(url.appending(path: "s")) { parent, start in
                parent.appending(path: bytes[start..<min(start + 100, bytes.count)].map { String(format: "%02x", $0) }.joined())
            }
        }.appending(path: "rows.json")
        return LastKnownList(store: self, file: file, generation: generation)
    }

    fileprivate func read<Value: Codable & Sendable>(_ type: Value.Type, at file: URL) -> Value? {
        if let value = memory.object(forKey: file as NSURL) as? Value { return value }
        // A cold first frame needs its own list before it can draw. Subsequent opens read memory.
        let value = io.sync { () -> Value? in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
        if let value { memory.setObject(value as AnyObject, forKey: file as NSURL) }
        return value
    }

    fileprivate func save<Value: Codable & Sendable>(_ value: Value, at file: URL) {
        memory.setObject(value as AnyObject, forKey: file as NSURL)
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
