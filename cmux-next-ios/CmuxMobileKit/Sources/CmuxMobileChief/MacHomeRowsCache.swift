import CmuxConversationCore
import Foundation
import os

/// Keeps each Mac's Home list as this phone last read it, per account, so Home shows those rows
/// at once on a launch or when that Mac is chosen again, instead of an empty list until the Mac
/// answers (the user, 2026-11-09: "never show an empty UI for data that exists but is still
/// loading"). The Mac's own list replaces them as soon as it arrives (``MacHomeFeed``).
///
/// One JSON file per account and Mac in Application Support (readable after first unlock, not in
/// backups), the newest ``rowLimit`` rows of each, all files together under ``byteLimit`` (the
/// lists written longest ago leave first). The rows read or written this run stay in memory, so a
/// Mac chosen again in the same run shows them in the same frame. Disk reads and writes run in
/// order on one utility queue, never on the main thread. Sign-out deletes them all (``removeAll()``).
public final class MacHomeRowsCache: @unchecked Sendable {
    /// Rows kept per Mac: the owner's order puts the pins and the newest conversations first.
    public static let rowLimit = 200
    /// Bytes kept on disk for every account and Mac together.
    public static let byteLimit = 2 * 1024 * 1024

    public static let standard: MacHomeRowsCache = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return MacHomeRowsCache(directory: base.appending(path: "cmux-mobile-home-rows", directoryHint: .isDirectory))
    }()

    public let directory: URL
    public let rowLimit: Int
    public let byteLimit: Int
    let queue = DispatchQueue(label: "dev.cmux.mobile.home-rows", qos: .utility)
    /// How long a write waits for newer rows (each Mac event reads the list again): one file
    /// write per key per `writeDelay`, of the newest rows.
    let writeDelay: DispatchTimeInterval
    /// Rows waiting for their write, by key; the queue takes the newest.
    private let pending = OSAllocatedUnfairLock(initialState: [String: [MacHomeRow]]())
    /// This run's rows by key. Read and written on the main actor only.
    @MainActor private var memory: [String: [MacHomeRow]] = [:]
    /// Bumps on `removeAll`: a read that started before it never lands in memory after it.
    @MainActor private var generation = 0

    public init(directory: URL, rowLimit: Int = MacHomeRowsCache.rowLimit, byteLimit: Int = MacHomeRowsCache.byteLimit,
                writeDelay: DispatchTimeInterval = .seconds(1)) {
        self.directory = directory
        self.rowLimit = rowLimit
        self.byteLimit = byteLimit
        self.writeDelay = writeDelay
    }

    /// The key of one account's Home list of one Mac.
    public static func key(account: String, macID: String) -> String { "\(account)|\(macID)" }

    /// The rows for `key` read or written this run, without touching the disk.
    @MainActor public func cached(_ key: String) -> [MacHomeRow]? { memory[key] }

    /// The rows for `key`: from memory, else read from disk off the main thread.
    @MainActor public func load(_ key: String) async -> [MacHomeRow]? {
        if let held = memory[key] { return held }
        let url = file(for: key), started = generation
        let read: [MacHomeRow]? = await withCheckedContinuation { continuation in
            queue.async {
                let data = try? Data(contentsOf: url)
                continuation.resume(returning: data.flatMap { try? JSONDecoder().decode([MacHomeRow].self, from: $0) })
            }
        }
        guard started == generation else { return nil }
        // A save during the read is newer than what was on disk.
        if let held = memory[key] { return held }
        if let read { memory[key] = read }
        return read
    }

    /// Keeps the first `rowLimit` of `rows` for `key`: in memory now, on disk on the queue.
    @MainActor public func save(_ key: String, rows: [MacHomeRow]) {
        let kept = Array(rows.prefix(rowLimit))
        guard memory[key] != kept else { return }
        memory[key] = kept
        let waiting = pending.withLock { pending in
            defer { pending[key] = kept }
            return pending[key] != nil
        }
        guard !waiting else { return }
        queue.asyncAfter(deadline: .now() + writeDelay) { [self] in write(key) }
    }

    /// Writes the newest rows waiting for `key`, if any (on the queue).
    private func write(_ key: String) {
        guard let rows = pending.withLock({ $0.removeValue(forKey: key) }),
              let data = try? JSONEncoder().encode(rows) else { return }
        var directory = directory
        if !FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // A copy of what the Mac lists: not in device backups.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
        }
        let written = file(for: key)
        guard (try? data.write(to: written, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil else { return }
        ConversationTranscriptCache.trim(directory, to: byteLimit, keeping: written)
    }

    /// Sign-out: every kept Home list leaves this device. Writes not yet made are dropped now;
    /// the files go on the queue, after any write already running.
    @MainActor public func removeAll() {
        memory = [:]
        generation += 1
        pending.withLock { $0 = [:] }
        let directory = directory
        queue.async { try? FileManager.default.removeItem(at: directory) }
    }

    /// Makes every waiting write now and returns once the queue is done (tests, never main-thread code).
    public func flush() {
        queue.sync {
            for key in pending.withLock({ Array($0.keys) }) { write(key) }
        }
    }

    private func file(for key: String) -> URL {
        let safe = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_" }.joined()
        return directory.appending(path: "\(safe.isEmpty ? "default" : safe).json")
    }
}
