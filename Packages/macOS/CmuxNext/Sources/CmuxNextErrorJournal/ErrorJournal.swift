public import Foundation
import CmuxNextWakeups

/// One durable, bounded error log for the app: every warning, error, fault and crash from
/// the app's own log, its pages' consoles, acpmux, the Chief and crash reports, deduplicated
/// by fingerprint with a count, first and last seen, and one redacted sample.
///
/// The logs are read on a demand only (``harvest(_:)``: `errors.list`, Copy Logs); nothing reads
/// them at rest.
///
/// The table, redaction, templates, fingerprints and every write decision are Rust's
/// (`cmux-error-journal`, through ``ErrorJournalFFI``); this actor does the file I/O and timers.
///
/// Writes are batched off the main actor (``ErrorJournalLimits/flushDelaySeconds``); storms
/// only bump counters; disk use stays below about twice ``ErrorJournalLimits/segmentBytes``.
///
/// ```swift
/// let journal = ErrorJournal(directory: tempDirectory)
/// await journal.record(ErrorEvent(source: "app", level: .error, message: "load failed"))
/// await journal.flush()
/// let newest = await journal.entries(ErrorQuery(limit: 10))
/// ```
public actor ErrorJournal {
    /// The folder of the segment files and harvest cursors.
    public nonisolated let directory: URL
    private let limits: ErrorJournalLimits
    private let now: @Sendable () -> Date
    /// This journal's table in Rust (`error_journal_*` ops): the directory plus a launch-unique tag.
    private nonisolated let id: String
    private var store: ErrorSegmentStore
    /// Whether ``openIfNeeded()`` read what earlier launches kept.
    private var opened = false
    private let flushTimer: DemandTimer
    /// The newest demand read (``harvest(_:)``): the running one, or the one that waits for it.
    private var lastRead: Task<[String: Int], Never>?
    /// Demand reads that have not ended: 0, 1 (one runs) or 2 (one runs, one waits).
    private var unfinishedReads = 0

    /// Opens (or creates) the journal in `directory`. Cheap: what earlier launches kept is read on
    /// the first call on the actor, never on the caller's thread.
    /// - Parameters:
    ///   - directory: The journal's own folder.
    ///   - limits: Disk, memory and storm bounds.
    ///   - clock: Times the batched write; tests pass their own.
    ///   - now: The current date; tests pass a fixed one.
    public init(directory: URL, limits: ErrorJournalLimits = ErrorJournalLimits(),
                clock: any Clock<Duration> = ContinuousClock(), now: @escaping @Sendable () -> Date = { Date() }) {
        // Nothing here reads the journal: the app opens it on the main thread at launch, and
        // reading and re-redacting up to 4 MiB there held it 3.1 s. The first call on the actor reads it.
        self.directory = directory
        self.limits = limits
        flushTimer = DemandTimer(owner: "error-journal.flush", clock: clock)
        self.now = now
        id = directory.path + "#" + UUID().uuidString
        store = ErrorSegmentStore(directory: directory)
    }

    deinit {
        _ = ErrorJournalFFI.data("error_journal_close", ["journal": id])
    }

    /// Reads what earlier launches kept, once, on the actor, and hands the lines to Rust, which
    /// re-redacts lines other rules wrote and asks for the rewrite. Every isolated entry point calls it first.
    private func openIfNeeded() {
        guard !opened else { return }
        opened = true
        let loaded = store.load()
        var request: [String: Any] = ["journal": id, "limits": limits.json, "segments": loaded.segments]
        if let currentBytes = loaded.currentBytes { request["current_bytes"] = currentBytes }
        let reply = ErrorJournalFFI.object("error_journal_open", request)
        perform(reply?["write"], purpose: "open")
    }

    /// Folds one occurrence into its entry and schedules the write.
    public func record(_ event: ErrorEvent) {
        record(contentsOf: [event])
    }

    /// Folds many occurrences and schedules one write.
    public func record(contentsOf events: [ErrorEvent]) {
        openIfNeeded()
        guard let advice = ErrorJournalFFI.object("error_journal_record",
                                                  ["journal": id, "events": events.map(ErrorJournalFFI.json)]) else { return }
        if advice["flush_now"] as? Bool == true {
            flush()
        } else if advice["schedule"] as? Bool == true {
            // A batching deadline that new records do not push back; flush() cancels it.
            flushTimer.scheduleIfIdle(after: .milliseconds(Int64(limits.flushDelaySeconds * 1000))) { [weak self] in
                await self?.flush()
            }
        }
    }

    /// Writes every pending change now.
    public func flush() {
        flushTimer.cancel()
        guard opened else { return }
        perform(ErrorJournalFFI.object("error_journal_flush", ["journal": id])?["write"], purpose: "flush")
    }

    /// The entries `query` selects, in its order.
    public func entries(_ query: ErrorQuery = ErrorQuery()) -> [ErrorEntry] {
        openIfNeeded()
        return ErrorJournalFFI.decode(EntriesReply.self, "error_journal_entries", ["journal": id, "query": query.json])?
            .entries ?? []
    }

    /// Distinct fingerprints kept.
    public var entryCount: Int {
        openIfNeeded()
        return ErrorJournalFFI.object("error_journal_count", ["journal": id])?["count"] as? Int ?? 0
    }

    /// Bytes of the segment files on disk.
    public var diskBytes: Int { store.diskBytes() }

    /// The last write failure, or nil when the last write worked.
    public var writeError: String? {
        openIfNeeded()
        return ErrorJournalFFI.object("error_journal_write_error", ["journal": id])?["error"] as? String
    }

    /// Forgets the given fingerprints (all of them when nil) and rewrites the file.
    /// - Returns: How many entries were removed.
    @discardableResult
    public func clear(fingerprints: [String]? = nil) -> Int {
        openIfNeeded()
        var request: [String: Any] = ["journal": id]
        if let fingerprints { request["fingerprints"] = fingerprints }
        guard let reply = ErrorJournalFFI.object("error_journal_clear", request) else { return 0 }
        let after = perform(["mode": "compact", "data": reply["data"] ?? ""], purpose: "clear")
        // A failed compaction can already have removed some old segments: Rust hands back the
        // pre-clear table so a relaunch cannot observe a partially cleared history.
        if let restore = after?["restore"] as? String {
            perform(["mode": "compact", "data": restore], purpose: "restore")
        }
        return after?["removed"] as? Int ?? 0
    }

    /// Reads every source after its saved cursor, folds what it found, saves the cursors and
    /// writes. A failing source becomes one `journal` warning; the others still run.
    ///
    /// Call it on a demand only (`errors.list`, Copy Logs): a read of the unified log costs seconds
    /// of CPU in the log service, so nothing reads at rest. One read runs at a time. A demand that
    /// comes while one runs waits for one more read, which starts when the running one ends and
    /// serves every demand that came before it started (with the sources of the first of them; the
    /// app has one list); so each demand gets a read that started after it, and at most one read waits.
    /// - Returns: New occurrences per source id.
    @discardableResult
    public func harvest(_ sources: [any ErrorHarvestSource]) async -> [String: Int] {
        if unfinishedReads == 2, let lastRead { return await lastRead.value }
        let running = unfinishedReads == 1 ? lastRead : nil
        unfinishedReads += 1
        // A task of its own: a demand that gives up (the 12 s deadline of `errors.list`) does not
        // cancel the read, so the cursors it moved are saved. It inherits this actor.
        let read = Task { () -> [String: Int] in
            _ = await running?.value
            let found = await self.readSources(sources)
            self.unfinishedReads -= 1
            return found
        }
        lastRead = read
        return await read.value
    }

    private func readSources(_ sources: [any ErrorHarvestSource]) async -> [String: Int] {
        openIfNeeded()
        var cursors = loadCursors()
        var found: [String: Int] = [:]
        var events: [ErrorEvent] = []
        for source in sources {
            do {
                let harvest = try await source.collect(after: cursors[source.id])
                events += harvest.events
                if let cursor = harvest.cursor { cursors[source.id] = cursor }
                found[source.id] = harvest.events.count
            } catch {
                events.append(ErrorEvent(source: "journal", level: .warning,
                                         message: "harvest of \(source.id) failed: \(error)", date: now()))
                found[source.id] = 0
            }
        }
        _ = ErrorJournalFFI.object("error_journal_record", ["journal": id, "events": events.map(ErrorJournalFFI.json)])
        saveCursors(cursors)
        flush()
        return found
    }

    private struct EntriesReply: Decodable {
        let entries: [ErrorEntry]
    }

    // MARK: - Writes

    /// Puts one write Rust asked for on disk and tells Rust how it went. An append whose file does
    /// not open becomes a compaction of the whole table.
    @discardableResult
    private func perform(_ write: Any?, purpose: String) -> [String: Any]? {
        guard let write = write as? [String: Any], var data = write["data"] as? String,
              var mode = write["mode"] as? String else { return nil }
        var outcome: ErrorSegmentStore.Outcome?
        if mode == "append" {
            outcome = store.append(Data(data.utf8))
            if outcome == nil {
                // Never compact an empty table over the journal because Rust did not answer.
                guard let all = ErrorJournalFFI.object("error_journal_compact_all", ["journal": id])?["data"] as? String
                else { return nil }
                mode = "compact"
                data = all
            }
        }
        let done = outcome ?? store.compact(Data(data.utf8))
        return ErrorJournalFFI.object("error_journal_written", [
            "journal": id, "mode": mode, "purpose": purpose, "written": done.written, "bytes": done.bytes,
            "error": done.error ?? NSNull(),
        ])
    }

    // MARK: - Cursors

    private var cursorsURL: URL { directory.appendingPathComponent("cursors.json") }

    private func loadCursors() -> [String: String] {
        guard let data = try? Data(contentsOf: cursorsURL),
              let cursors = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return cursors
    }

    private func saveCursors(_ cursors: [String: String]) {
        try? ErrorSegmentStore.protectDirectory(directory)
        if let data = try? JSONEncoder().encode(cursors),
           (try? data.write(to: cursorsURL, options: .atomic)) != nil {
            try? ErrorSegmentStore.protectFile(cursorsURL)
        }
    }
}
