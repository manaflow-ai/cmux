import CryptoKit
import Foundation
import os

/// The newest messages of a conversation as this device last saw them, so a store built again
/// (the app back from the background, a relaunch, a reconnect) shows them at once instead of a
/// spinner, the way Messages and WhatsApp keep a chat on the phone. The server's newest page
/// replaces them as soon as it arrives (`ConversationStore.applyNewest`).
public struct ConversationTranscriptSnapshot: Sendable, Hashable, Codable {
    public var info: ConversationInfo?
    public var meID: String?
    /// Acknowledged messages, oldest first, at most `ConversationTranscriptCache.limit`.
    public var messages: [ConversationMessage]

    public init(info: ConversationInfo?, meID: String?, messages: [ConversationMessage]) {
        self.info = info
        self.meID = meID
        self.messages = messages
    }
}

/// Every conversation's history on this device, in one SQLite database per account
/// (`ConversationHistoryDatabase`, Application Support, readable after first unlock, not in
/// backups): what the stores read and what ``sync(_:pageSize:fetch:)`` backfilled. A store built
/// again shows the newest ``limit`` messages at once (from memory in the same run, else read off
/// the main thread), and with no network it pages older ones from here (`ConversationStore.loadOlder`).
///
/// Account isolation: ``activate(account:)`` picks the account's own file; another account's
/// rows are never read, and a read or sync begun for one account never lands after a switch.
/// Sign-out deletes every file (``removeAll()``). Disk work runs in order on one utility queue.
public final class ConversationTranscriptCache: @unchecked Sendable {
    /// Messages a store shows at once from here; older ones page in as the reader scrolls up.
    public static let limit = 200
    /// Bytes the history database may hold before a write trims it: the conversations written
    /// longest ago lose their oldest messages first, never the newest `limit` of any one (the
    /// user, 2026-11-09: "chats preserved on disk up to a storage limit, latest kept").
    public static let byteLimit = 256 * 1024 * 1024

    public let directory: URL
    public let limit: Int
    public let byteLimit: Int
    let queue = DispatchQueue(label: "dev.cmux.conversation.transcript-cache", qos: .utility)
    /// How long a write waits for newer changes (a streamed reply changes the transcript many
    /// times a second): one write per key per `writeDelay`, of what changed since the last.
    let writeDelay: DispatchTimeInterval

    /// Which account the cache serves now, and a counter that bumps on every switch and on
    /// sign-out: work started under an older one is dropped. Read on the queue too.
    struct Scope: Sendable, Equatable {
        var account: String?
        var generation: Int
    }
    private let scopeLock = OSAllocatedUnfairLock(initialState: Scope(account: nil, generation: 0))
    var scope: Scope { scopeLock.withLock { $0 } }

    /// What a store saved and the queue has not written yet, by account and key.
    struct PendingWrite {
        var account: String?
        var generation: Int
        var key: String
        var info: ConversationInfo?
        var meID: String?
        var changed: [String: ConversationMessage] = [:]
        var deleted: Set<String> = []
        var window: ClosedRange<Int>?
        var reachedStart = false
    }
    private let pending = OSAllocatedUnfairLock(initialState: [String: PendingWrite]())
    /// The generation of the last ``removeAll()``: a write made before it never lands.
    private let removedGeneration = OSAllocatedUnfairLock(initialState: 0)

    /// This run's snapshots by key. Main actor only.
    @MainActor private var memory: [String: ConversationTranscriptSnapshot] = [:]
    /// What each key's last save wrote, by message id: the next save writes only what changed.
    @MainActor private var written: [String: [String: ConversationMessage]] = [:]
    /// Ids each key's saves already deleted for me.
    @MainActor private var deletedWritten: [String: Set<String>] = [:]

    /// The open database and the account it is for. Queue only.
    private var database: ConversationHistoryDatabase?
    private var databaseAccount: String??

    public init(directory: URL, limit: Int = ConversationTranscriptCache.limit, byteLimit: Int = ConversationTranscriptCache.byteLimit,
                writeDelay: DispatchTimeInterval = .seconds(1)) {
        self.directory = directory
        self.limit = limit
        self.byteLimit = byteLimit
        self.writeDelay = writeDelay
    }

    /// The cache in Application Support/`name`. `replacing` names folders an older build kept
    /// conversations in (the JSON files of the first kept-transcript build): they are removed.
    public static func inApplicationSupport(_ name: String, replacing legacy: [String] = []) -> ConversationTranscriptCache {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let cache = ConversationTranscriptCache(directory: base.appending(path: name, directoryHint: .isDirectory))
        if !legacy.isEmpty {
            cache.queue.async {
                for folder in legacy { try? FileManager.default.removeItem(at: base.appending(path: folder, directoryHint: .isDirectory)) }
            }
        }
        return cache
    }

    // MARK: Account

    /// The account whose history the cache reads and writes from now on (nil: signed out, a
    /// device-only file). Kept rows of the previous account leave memory at once.
    @MainActor public func activate(account: String?) {
        guard scope.account != account else { return }
        scopeLock.withLock { $0 = Scope(account: account, generation: $0.generation + 1) }
        // What the previous account saved goes to its own file now, before any read for the
        // next account (or for it again) runs on the queue.
        queue.async { [self] in
            for slot in pending.withLock({ Array($0.keys) }) { write(slot) }
        }
        memory = [:]
        written = [:]
        deletedWritten = [:]
    }

    /// The account the cache serves now.
    @MainActor public var account: String? { scope.account }

    // MARK: Reads

    /// The snapshot for `key` read or written this run, without touching the disk.
    @MainActor public func cached(_ key: String) -> ConversationTranscriptSnapshot? { memory[key] }

    /// The snapshot for `key`: from memory, else read from disk off the main thread.
    @MainActor public func load(_ key: String) async -> ConversationTranscriptSnapshot? {
        if let held = memory[key] { return held }
        let started = scope, limit = limit
        let read: ConversationTranscriptSnapshot? = try? await run(started) { db in
            let messages = try db.newest(key, limit: limit)
            let head = try db.info(key)
            guard !messages.isEmpty || head != nil else { return nil }
            return ConversationTranscriptSnapshot(info: head?.info, meID: head?.meID, messages: messages)
        }
        guard started == scope else { return nil }
        // A save during the read is newer than what was on disk.
        if let held = memory[key] { return held }
        if let read { memory[key] = read }
        return read
    }

    /// Up to `limit` stored messages older than `beforeSeq`, oldest first, as a history page:
    /// what a store shows with no server page (offline, or still connecting). Online, older
    /// pages come from the server, which has edits and unsends made while the phone was away.
    /// Nil after an account switch or a failed read.
    @MainActor public func older(_ key: String, beforeSeq: Int, limit: Int) async -> ConversationHistoryPage? {
        let started = scope
        let page: ConversationHistoryPage? = try? await run(started) { db in
            let rows = try db.older(key, beforeSeq: beforeSeq, limit: limit)
            return ConversationHistoryPage(messages: rows, hasMore: rows.count == limit)
        }
        guard started == scope else { return nil }
        return page
    }

    /// How much of `key` is stored without gaps (tests, diagnostics).
    public func syncedRange(_ key: String) async -> ConversationHistoryRange? {
        try? await run(scope) { try $0.syncedRange(key) }
    }

    /// How many messages of `key` are stored (tests, diagnostics).
    public func storedCount(_ key: String) async -> Int {
        (try? await run(scope) { try $0.count(key) }) ?? 0
    }

    // MARK: Writes

    /// Keeps the store's transcript for `key`: the newest `limit` in memory now, and every
    /// acknowledged message that changed since the last save on disk, on the queue. Sends not yet
    /// acknowledged, Send Later rows and image bytes are not kept (the outbox owns unsent
    /// messages). `deleted`: rows deleted for me, which leave the disk for good. `reachedStart`:
    /// the store holds the conversation's first message, so its history is stored whole.
    @MainActor public func save(_ key: String, info: ConversationInfo?, meID: String?, messages: [ConversationMessage],
                                deleted: Set<String> = [], reachedStart: Bool = false) {
        let snapshot = Self.snapshot(info: info, meID: meID, messages: messages, limit: limit)
        var before = written[key] ?? [:]
        var changed: [String: ConversationMessage] = [:]
        var low = Int.max, high = Int.min
        for message in messages where message.seq != nil && !message.isScheduled {
            let stored = ConversationHistoryDatabase.stored(message)
            if let seq = stored.seq { low = min(low, seq); high = max(high, seq) }
            if before[stored.id] != stored {
                before[stored.id] = stored
                changed[stored.id] = stored
            }
        }
        let newlyDeleted = deleted.subtracting(deletedWritten[key] ?? [])
        for id in newlyDeleted { before[id] = nil }
        deletedWritten[key, default: []].formUnion(newlyDeleted)
        let infoChanged = memory[key]?.info != info || memory[key]?.meID != meID
        written[key] = before
        memory[key] = snapshot
        guard !changed.isEmpty || !newlyDeleted.isEmpty || infoChanged || reachedStart else { return }
        let current = scope, account = current.account
        let slot = "\(account ?? "")\u{1F}\(key)"
        let window = low <= high ? low...high : nil
        let changedRows = changed
        let waiting = pending.withLock { pending in
            let waiting = pending[slot] != nil
            var write = pending[slot] ?? PendingWrite(account: account, generation: current.generation, key: key)
            write.info = info
            write.meID = meID
            write.changed.merge(changedRows) { $1 }
            for id in newlyDeleted { write.changed[id] = nil }
            write.deleted.formUnion(newlyDeleted)
            write.window = window
            write.reachedStart = reachedStart
            pending[slot] = write
            return waiting
        }
        guard !waiting else { return }
        queue.asyncAfter(deadline: .now() + writeDelay) { [self] in write(slot) }
    }

    /// Writes what waits under `slot`, if anything (on the queue).
    private func write(_ slot: String) {
        guard let write = pending.withLock({ $0.removeValue(forKey: slot) }),
              write.generation >= removedGeneration.withLock({ $0 }),
              let db = try? database(for: write.account) else { return }
        // The store's window has no gap: it widens the synced range it overlaps (or starts one).
        var range: ConversationHistoryDatabase.SyncedRange?? = nil
        if let window = write.window {
            let current = try? db.syncedRange(write.key)
            if let current, window.lowerBound <= current.newestSeq + 1, window.upperBound >= current.oldestSeq {
                let oldest = min(current.oldestSeq, window.lowerBound)
                range = .some(.init(oldestSeq: oldest, newestSeq: max(current.newestSeq, window.upperBound),
                                    complete: current.complete || (write.reachedStart && oldest == window.lowerBound)))
            } else if current == nil {
                range = .some(.init(oldestSeq: window.lowerBound, newestSeq: window.upperBound, complete: write.reachedStart))
            }
        }
        try? db.write(write.key, messages: Array(write.changed.values), info: .some(write.info), meID: .some(write.meID),
                      range: range, deleting: write.deleted)
        try? db.trim(to: byteLimit, keepingNewest: limit)
    }

    /// Deletes the files of `directory` written longest ago until the rest fit in `byteLimit`
    /// bytes, never `keeping` (the file just written). Runs on the caller's queue, never the main
    /// thread. The other on-disk caches with a total limit use it (Home rows, agent transcripts).
    public static func trim(_ directory: URL, to byteLimit: Int, keeping: URL?) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
                                                                       options: [.skipsHiddenFiles]) else { return }
        let kept = keeping?.standardizedFileURL.path(percentEncoded: false)
        var total = 0
        var candidates: [(url: URL, size: Int, date: Date)] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            total += size
            if url.standardizedFileURL.path(percentEncoded: false) != kept {
                candidates.append((url, size, values.contentModificationDate ?? .distantPast))
            }
        }
        guard total > byteLimit else { return }
        for candidate in candidates.sorted(by: { $0.date < $1.date }) {
            guard total > byteLimit else { break }
            if (try? FileManager.default.removeItem(at: candidate.url)) != nil { total -= candidate.size }
        }
    }

    /// Sign-out: every kept conversation of every account leaves this device. Writes not yet
    /// made are dropped now; the files go on the queue, after any write already running.
    @MainActor public func removeAll() {
        memory = [:]
        written = [:]
        deletedWritten = [:]
        // Signed out: nothing is read or written for the account that was active.
        let generation = scopeLock.withLock { scope -> Int in
            scope = Scope(account: nil, generation: scope.generation + 1)
            return scope.generation
        }
        removedGeneration.withLock { $0 = generation }
        pending.withLock { $0 = [:] }
        queue.async { [self] in
            database = nil
            databaseAccount = nil
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Makes every waiting write now and returns once the queue is done (tests, never main-thread code).
    public func flush() {
        queue.sync {
            for slot in pending.withLock({ Array($0.keys) }) { write(slot) }
        }
    }

    // MARK: Queue

    /// Runs `body` on the queue against `scope`'s database; throws `CancellationError` when the
    /// account changed or signed out since `scope` was read.
    func run<T: Sendable>(_ scope: Scope, _ body: @escaping @Sendable (ConversationHistoryDatabase) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard self.scope == scope else { return continuation.resume(throwing: CancellationError()) }
                continuation.resume(with: Result { try body(try database(for: scope.account)) })
            }
        }
    }

    /// The database of `account`, opened (created) on first use. Queue only.
    private func database(for account: String?) throws -> ConversationHistoryDatabase {
        if let database, databaseAccount == .some(account) { return database }
        var folder = directory
        if !FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            // Kept messages are a copy of the server's: not in device backups.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
        }
        database = nil
        let opened = try ConversationHistoryDatabase(url: directory.appending(path: Self.fileName(account: account)))
        database = opened
        databaseAccount = .some(account)
        return opened
    }

    /// One file per account, named by a hash so no account id is on disk in clear.
    static func fileName(account: String?) -> String {
        guard let account else { return "history-signed-out.sqlite" }
        let digest = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
        return "history-\(digest.prefix(32)).sqlite"
    }

    nonisolated static func snapshot(info: ConversationInfo?, meID: String?, messages: [ConversationMessage], limit: Int) -> ConversationTranscriptSnapshot {
        // From the end: a long transcript (older pages loaded) is not walked whole.
        let kept = messages.lazy.filter { $0.seq != nil && !$0.isScheduled }.suffix(limit).map(ConversationHistoryDatabase.stored)
        return ConversationTranscriptSnapshot(info: info, meID: meID, messages: Array(kept))
    }
}
