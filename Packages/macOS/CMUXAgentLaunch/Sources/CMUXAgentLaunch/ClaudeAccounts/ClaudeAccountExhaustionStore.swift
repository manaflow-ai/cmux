import Foundation

/// Tracks which Claude accounts hit a usage limit and until when.
///
/// File format: `{"version":1,"exhaustedUntil":{"<accountKey>":<epochSeconds>}}`. The app is
/// the only writer; the CLI only reads. Corrupt or wrong-version files read as empty and the
/// next write replaces them. Reads never rewrite the file; pruning happens on writes.
///
/// Writes are serialized through the actor: each reads the file, changes one entry and swaps a
/// new file in with an atomic rename, so overlapping writes never drop each other's entries.
/// ``exhaustedUntil(now:)`` reads on the actor, after any write already started.
///
/// For a caller that has no `await`, such as `cmux claude-account list`,
/// ``snapshotExhaustedUntil(now:)`` is a `nonisolated` synchronous read of the file. Because
/// every write replaces the whole file with one rename, it sees either the old or the new file,
/// never a partial one, and needs no lock.
public actor ClaudeAccountExhaustionStore {
    private static let version = 1

    /// The file this store reads and writes.
    public nonisolated let fileURL: URL
    private let clock: @Sendable () -> Date

    /// `clock` decides which stored entries a write prunes as expired.
    public init(fileURL: URL, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.clock = clock
    }

    /// `~/.cmuxterm/claude-account-exhaustion.json`.
    public static func defaultFileURL(homeDirectory: String) -> URL {
        URL(fileURLWithPath: (homeDirectory as NSString).standardizingPath, isDirectory: true)
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("claude-account-exhaustion.json")
    }

    public func markExhausted(accountKey: String, until: Date) throws {
        try mutate(now: clock()) { $0[accountKey] = until.timeIntervalSince1970 }
    }

    public func clear(accountKey: String) throws {
        try mutate(now: clock()) { $0.removeValue(forKey: accountKey) }
    }

    /// Entries whose reset time is still in the future at `now`, read after any write already
    /// started on this store.
    public func exhaustedUntil(now: Date) -> [String: Date] {
        Self.unexpired(Self.readEntries(fileURL: fileURL), now: now)
    }

    /// Entries whose reset time is still in the future at `now`, read from the file directly
    /// without hopping onto the actor. For callers that cannot `await`; see the type's notes.
    public nonisolated func snapshotExhaustedUntil(now: Date) -> [String: Date] {
        Self.unexpired(Self.readEntries(fileURL: fileURL), now: now)
    }

    private func mutate(now: Date, _ change: (inout [String: Double]) -> Void) throws {
        var entries = Self.readEntries(fileURL: fileURL)
        change(&entries)
        let cutoff = now.timeIntervalSince1970
        entries = entries.filter { $0.value > cutoff }
        try write(entries)
    }

    private static func unexpired(_ entries: [String: Double], now: Date) -> [String: Date] {
        let cutoff = now.timeIntervalSince1970
        return entries.reduce(into: [:]) { result, entry in
            if entry.value > cutoff { result[entry.key] = Date(timeIntervalSince1970: entry.value) }
        }
    }

    private static func readEntries(fileURL: URL) -> [String: Double] {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["version"] as? Int) == version,
              let raw = object["exhaustedUntil"] as? [String: Any]
        else { return [:] }
        var entries: [String: Double] = [:]
        for (key, value) in raw {
            if let seconds = (value as? NSNumber)?.doubleValue, seconds.isFinite { entries[key] = seconds }
        }
        return entries
    }

    private func write(_ entries: [String: Double]) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let payload: [String: Any] = ["version": Self.version, "exhaustedUntil": entries]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let temp = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            if rename(temp.path, fileURL.path) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
    }
}
