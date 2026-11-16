import CmuxConversationCore
import CmuxMobileAgentChat
import Foundation
import os

/// The newest acpmux records of one agent chat as this phone last applied them, so a chat opened
/// again (a relaunch, the Mac's link still coming up, a store rebuilt) draws its transcript at once
/// and then catches up from the last record kept, instead of showing the empty new-chat screen
/// until the Mac answers (user 2026-11-09: "I get shown a new chat UI until the full chat loads").
public struct AgentTranscriptEntry: Sendable, Hashable, Codable {
    /// The acpmux session the records belong to: a tab bound to another session keeps none.
    public var sessionID: String
    /// The Mac holds records older than the first one kept.
    public var earlier: Bool
    /// Records oldest first, starting at a prompt (`user_message`).
    public var records: [JSONValue]

    public init(sessionID: String, earlier: Bool, records: [JSONValue]) {
        self.sessionID = sessionID
        self.earlier = earlier
        self.records = records
    }

    /// The newest seq kept (0: none).
    public var lastSeq: Int { Int(records.last?["seq"]?.numberValue ?? 0) }
}

/// Keeps one `AgentTranscriptEntry` per chat (account, Mac and tab) on disk, in Application
/// Support (readable after first unlock, not backed up), and the chats used this run in memory.
///
/// Bounds, newest kept:
/// - each chat keeps at most `recordLimit` records and `entryBytes` bytes, cut at a prompt so it
///   starts on a whole turn (older turns come from the Mac as the reader scrolls up);
/// - every chat together keeps at most `totalBytes` on disk: after a write, the chats written
///   longest ago are deleted until the folder fits;
/// - memory holds at most `memoryEntries` chats, the most recently used.
///
/// Disk reads and writes run in order on one utility queue, never on the main thread; a write
/// waits `writeDelay` for newer records (a streamed reply adds several a second). Sign-out
/// deletes them all (`removeAll`).
public final class AgentTranscriptCache: @unchecked Sendable {
    public static let standard = AgentTranscriptCache.inApplicationSupport("agent-chat-transcripts")

    public let directory: URL
    public let recordLimit: Int
    public let entryBytes: Int
    public let totalBytes: Int
    public let memoryEntries: Int
    let writeDelay: DispatchTimeInterval
    let queue = DispatchQueue(label: "dev.cmux.mobile.agent-transcript-cache", qos: .utility)
    /// Entries waiting for their write, by key; the queue takes the newest.
    private let pending = OSAllocatedUnfairLock(initialState: [String: AgentTranscriptEntry]())
    /// This run's entries by key, most recently used last. Main actor only.
    @MainActor private var memory: [String: AgentTranscriptEntry] = [:]
    @MainActor private var recent: [String] = []
    /// Bumps on `removeAll`: a read that started before it never lands after it.
    @MainActor private var generation = 0

    public init(directory: URL, recordLimit: Int = 600, entryBytes: Int = 512 * 1024, totalBytes: Int = 48 << 20,
                memoryEntries: Int = 12, writeDelay: DispatchTimeInterval = .seconds(1)) {
        self.directory = directory
        self.recordLimit = recordLimit
        self.entryBytes = entryBytes
        self.totalBytes = totalBytes
        self.memoryEntries = memoryEntries
        self.writeDelay = writeDelay
    }

    public static func inApplicationSupport(_ name: String) -> AgentTranscriptCache {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return AgentTranscriptCache(directory: base.appending(path: name, directoryHint: .isDirectory))
    }

    /// The chat's key: tab ids repeat across Macs, and each account keeps its own.
    /// Nil without an account (nothing is kept for a chat no account owns).
    public static func key(accountID: String, macID: String, tabID: String) -> String? {
        guard !accountID.isEmpty, !tabID.isEmpty else { return nil }
        return [accountID, macID, tabID].joined(separator: "|")
    }

    /// The entry for `key` read or written this run, without touching the disk.
    @MainActor public func cached(_ key: String) -> AgentTranscriptEntry? {
        guard let entry = memory[key] else { return nil }
        touch(key)
        return entry
    }

    /// The entry for `key`: from memory, else read from disk off the main thread.
    @MainActor public func load(_ key: String) async -> AgentTranscriptEntry? {
        if let held = cached(key) { return held }
        let url = file(for: key), started = generation
        let read: AgentTranscriptEntry? = await withCheckedContinuation { continuation in
            queue.async {
                let data = try? Data(contentsOf: url)
                continuation.resume(returning: data.flatMap { try? JSONDecoder().decode(AgentTranscriptEntry.self, from: $0) })
            }
        }
        guard started == generation else { return nil }
        // A save during the read is newer than what was on disk.
        if let held = cached(key) { return held }
        if let read { remember(key, read) }
        return read
    }

    /// Keeps `records` (oldest first, from a prompt) for `key`: in memory now, bounded on disk later.
    @MainActor public func save(_ key: String, sessionID: String, earlier: Bool, records: [JSONValue]) {
        guard !records.isEmpty else { return }
        let entry = AgentTranscriptEntry(sessionID: sessionID, earlier: earlier, records: records)
        guard memory[key] != entry else { return }
        remember(key, entry)
        let waiting = pending.withLock { pending in
            defer { pending[key] = entry }
            return pending[key] != nil
        }
        guard !waiting else { return }
        queue.asyncAfter(deadline: .now() + writeDelay) { [self] in write(key) }
    }

    /// Forgets one chat's kept copy (too old to catch up from), in memory and on disk.
    @MainActor public func forget(_ key: String) {
        memory[key] = nil
        recent.removeAll { $0 == key }
        pending.withLock { _ = $0.removeValue(forKey: key) }
        let url = file(for: key)
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Sign-out: every kept chat leaves this device.
    @MainActor public func removeAll() {
        memory = [:]
        recent = []
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

    @MainActor private func remember(_ key: String, _ entry: AgentTranscriptEntry) {
        memory[key] = entry
        touch(key)
        while recent.count > memoryEntries {
            memory[recent.removeFirst()] = nil
        }
    }

    @MainActor private func touch(_ key: String) {
        recent.removeAll { $0 == key }
        recent.append(key)
    }

    /// Writes the newest entry waiting for `key`, then trims the folder to `totalBytes` (on the queue).
    private func write(_ key: String) {
        guard let entry = pending.withLock({ $0.removeValue(forKey: key) }) else { return }
        guard let data = Self.encoded(entry, recordLimit: recordLimit, entryBytes: entryBytes) else {
            // Not even the newest turn fits: an older copy must not stay behind it.
            try? FileManager.default.removeItem(at: file(for: key))
            return
        }
        var directory = directory
        if !FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // A copy of what the Mac keeps: not in device backups.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
        }
        let url = file(for: key)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        ConversationTranscriptCache.trim(directory, to: totalBytes, keeping: url)
    }

    /// The entry bounded to `recordLimit` records and `entryBytes` bytes, newest kept, starting
    /// at a prompt; nil when not even the newest turn fits.
    static func encoded(_ entry: AgentTranscriptEntry, recordLimit: Int, entryBytes: Int) -> Data? {
        var bounded = entry
        if bounded.records.count > recordLimit {
            bounded.records = Self.fromPrompt(Array(bounded.records.suffix(recordLimit)))
            bounded.earlier = true
        }
        let encoder = JSONEncoder()
        while !bounded.records.isEmpty {
            guard let data = try? encoder.encode(bounded) else { return nil }
            if data.count <= entryBytes { return data }
            // Drop the oldest turn: from the second prompt on.
            let rest = Array(bounded.records.dropFirst())
            guard let next = rest.firstIndex(where: Self.isPrompt) else { return nil }
            bounded.records = Array(rest[next...])
            bounded.earlier = true
        }
        return nil
    }

    /// `records` from their first prompt (the rest belongs to an older turn).
    static func fromPrompt(_ records: [JSONValue]) -> [JSONValue] {
        guard let first = records.firstIndex(where: isPrompt) else { return [] }
        return Array(records[first...])
    }

    static func isPrompt(_ record: JSONValue) -> Bool {
        record["kind"]?.stringValue == "user_message" && record["msg"]?["steer"] != .bool(true)
    }

    func file(for key: String) -> URL {
        let safe = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_" }.joined()
        return directory.appending(path: "\(safe.isEmpty ? "default" : safe).json")
    }
}
