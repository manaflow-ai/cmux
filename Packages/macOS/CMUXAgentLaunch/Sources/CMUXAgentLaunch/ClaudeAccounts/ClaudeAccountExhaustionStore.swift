import Foundation

/// Tracks which Claude accounts hit a usage limit and until when.
///
/// File format: `{"version":1,"exhaustedUntil":{"<accountKey>":<epochSeconds>}}`. The app is
/// the only writer; the CLI only reads. Corrupt or wrong-version files read as empty and the
/// next write replaces them. Reads never rewrite the file; pruning happens on writes.
///
/// A class guarded by `NSLock` rather than an actor: the `cmux claude-account list` CLI reads it
/// synchronously, outside any concurrency context, and each locked section is one small file
/// read or an atomic rename. `@unchecked Sendable` is sound because every access to the file
/// goes through `lock`, and the stored properties are immutable `let`s (the clock is
/// `@Sendable`).
public final class ClaudeAccountExhaustionStore: @unchecked Sendable {
    private static let version = 1

    private let fileURL: URL
    private let clock: @Sendable () -> Date
    private let lock = NSLock()

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

    /// Entries whose reset time is still in the future at `now`.
    public func exhaustedUntil(now: Date) -> [String: Date] {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = now.timeIntervalSince1970
        return readEntries().reduce(into: [:]) { result, entry in
            if entry.value > cutoff { result[entry.key] = Date(timeIntervalSince1970: entry.value) }
        }
    }

    private func mutate(now: Date, _ change: (inout [String: Double]) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var entries = readEntries()
        change(&entries)
        let cutoff = now.timeIntervalSince1970
        entries = entries.filter { $0.value > cutoff }
        try write(entries)
    }

    private func readEntries() -> [String: Double] {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["version"] as? Int) == Self.version,
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
