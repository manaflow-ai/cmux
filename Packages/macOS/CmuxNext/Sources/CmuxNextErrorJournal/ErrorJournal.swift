public import Foundation
import CmuxNextWakeups

/// One durable, bounded error log for the app: every warning, error, fault and crash from
/// the app's own log, its pages' consoles, acpmux, the Chief and crash reports, deduplicated
/// by fingerprint with a count, first and last seen, and one redacted sample.
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
    private let normalizer: ErrorNormalizer
    private let redactor: ErrorRedactor
    private var store: ErrorSegmentStore
    /// The segments were read (``loadIfNeeded()``); nothing reads them in `init`.
    private var loaded = false
    private var table: [String: ErrorEntry] = [:]
    private var dirty: Set<String> = []
    private let flushTimer: DemandTimer
    private var newFingerprints: [String: (minute: Int64, count: Int)] = [:]
    private var lastWriteError: String?

    /// Makes the journal for `directory`. Touches no disk: the first use (a record, a query, a
    /// harvest) creates the folder and reads what earlier launches kept, on this actor, so the app
    /// can make its journal at the composition root on the main thread.
    /// - Parameters:
    ///   - directory: The journal's own folder.
    ///   - limits: Disk, memory and storm bounds.
    ///   - clock: Times the batched write; tests pass their own.
    ///   - now: The current date; tests pass a fixed one.
    public init(directory: URL, limits: ErrorJournalLimits = ErrorJournalLimits(),
                clock: any Clock<Duration> = ContinuousClock(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.limits = limits
        flushTimer = DemandTimer(owner: "error-journal.flush", clock: clock)
        self.now = now
        normalizer = ErrorNormalizer(maxBytes: limits.maxMessageBytes)
        redactor = ErrorRedactor()
        store = ErrorSegmentStore(directory: directory, segmentBytes: limits.segmentBytes)
    }

    /// Reads what earlier launches kept, once, before the first use: every snapshot is redacted
    /// again and refingerprinted (a secret in shadowed history still triggers compaction), and the
    /// newest per fingerprint wins.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let snapshots = store.load()
        var latestByOriginalFingerprint: [String: ErrorEntry] = [:]
        var changed = false
        for var entry in snapshots {
            let original = entry
            let template = redactor.redact(entry.template).utf8Prefix(limits.maxMessageBytes)
            let sample = redactor.redact(entry.sample).utf8Prefix(limits.maxMessageBytes)
            let topFrame = entry.topFrame.map { redactor.redact($0).utf8Prefix(256) }
            let context = entry.context.mapValues {
                redactor.redact($0).utf8Prefix(limits.maxContextValueBytes)
            }
            entry.template = template
            entry.sample = sample
            entry.topFrame = topFrame
            entry.context = context
            entry.fingerprint = ErrorFingerprint(
                source: entry.source,
                template: template,
                topFrame: topFrame
            ).hex
            if entry != original { changed = true }
            latestByOriginalFingerprint[original.fingerprint] = entry
        }
        var loadedTable: [String: ErrorEntry] = [:]
        for originalFingerprint in latestByOriginalFingerprint.keys.sorted() {
            guard let entry = latestByOriginalFingerprint[originalFingerprint] else { continue }
            loadedTable[entry.fingerprint] = Self.mergeLoaded(loadedTable[entry.fingerprint], with: entry)
        }
        if changed {
            do { try store.compact(loadedTable.values.sorted { $0.lastMs < $1.lastMs }) }
            catch { lastWriteError = String(describing: error) }
        }
        table = loadedTable
    }

    private static func mergeLoaded(_ existing: ErrorEntry?, with incoming: ErrorEntry) -> ErrorEntry {
        guard var merged = existing else { return incoming }
        merged.count &+= incoming.count
        merged.level = max(merged.level, incoming.level)
        merged.firstMs = min(merged.firstMs, incoming.firstMs)
        if incoming.lastMs >= merged.lastMs {
            merged.lastMs = incoming.lastMs
            merged.sample = incoming.sample
            merged.context = incoming.context
        }
        return merged
    }

    /// Folds one occurrence into its entry and schedules the write.
    public func record(_ event: ErrorEvent) {
        loadIfNeeded()
        fold(event)
        scheduleFlush()
    }

    /// Folds many occurrences and schedules one write.
    public func record(contentsOf events: [ErrorEvent]) {
        loadIfNeeded()
        for event in events { fold(event) }
        scheduleFlush()
    }

    /// Writes every pending change now.
    public func flush() {
        loadIfNeeded()
        flushTimer.cancel()
        guard !dirty.isEmpty else { return }
        let changed = dirty.compactMap { table[$0] }.sorted { $0.lastMs < $1.lastMs }
        dirty.removeAll()
        do {
            try store.write(changed: changed, all: { table.values.sorted { $0.lastMs < $1.lastMs } })
            lastWriteError = nil
        } catch {
            lastWriteError = String(describing: error)
        }
    }

    /// The entries `query` selects, in its order.
    public func entries(_ query: ErrorQuery = ErrorQuery()) -> [ErrorEntry] {
        loadIfNeeded()
        let matching = table.values.filter(query.matches)
        let sorted: [ErrorEntry] = switch query.order {
        case .recent: matching.sorted { ($0.lastMs, $0.count) > ($1.lastMs, $1.count) }
        case .count: matching.sorted { ($0.count, $0.lastMs) > ($1.count, $1.lastMs) }
        }
        return Array(sorted.prefix(max(0, query.limit)))
    }

    /// Distinct fingerprints kept.
    public var entryCount: Int {
        loadIfNeeded()
        return table.count
    }

    /// Bytes of the segment files on disk.
    public var diskBytes: Int {
        loadIfNeeded()
        return store.diskBytes()
    }

    /// The last write failure, or nil when the last write worked.
    public var writeError: String? {
        loadIfNeeded()
        return lastWriteError
    }

    /// Forgets the given fingerprints (all of them when nil) and rewrites the file.
    /// - Returns: How many entries were removed.
    @discardableResult
    public func clear(fingerprints: [String]? = nil) -> Int {
        loadIfNeeded()
        var candidate = table
        let removed: Int
        if let fingerprints {
            removed = fingerprints.reduce(0) { $0 + (candidate.removeValue(forKey: $1) == nil ? 0 : 1) }
        } else {
            removed = candidate.count
            candidate.removeAll()
        }
        do {
            try store.compact(candidate.values.sorted { $0.lastMs < $1.lastMs })
            table = candidate
            dirty.removeAll()
            lastWriteError = nil
            return removed
        } catch {
            let clearError = String(describing: error)
            // A failed compaction can already have removed some old segments.
            // Rewrite the authoritative pre-clear table so a relaunch cannot
            // observe a partially cleared history while cleanup is retried.
            try? store.compact(table.values.sorted { $0.lastMs < $1.lastMs })
            lastWriteError = clearError
            return 0
        }
    }

    /// Reads every source after its saved cursor, folds what it found, saves the cursors and
    /// writes. A failing source becomes one `journal` warning; the others still run.
    /// - Returns: New occurrences per source id.
    @discardableResult
    public func harvest(_ sources: [any ErrorHarvestSource]) async -> [String: Int] {
        loadIfNeeded()
        var cursors = loadCursors()
        var found: [String: Int] = [:]
        for source in sources {
            do {
                let harvest = try await source.collect(after: cursors[source.id])
                for event in harvest.events { fold(event) }
                if let cursor = harvest.cursor { cursors[source.id] = cursor }
                found[source.id] = harvest.events.count
            } catch {
                fold(ErrorEvent(source: "journal", level: .warning, message: "harvest of \(source.id) failed: \(error)",
                                date: now()))
                found[source.id] = 0
            }
        }
        saveCursors(cursors)
        flush()
        return found
    }

    // MARK: - Folding

    private func fold(_ event: ErrorEvent) {
        var event = event
        let template = normalizer.template(redactor.redact(event.message))
        let topFrame = event.topFrame.map { redactor.redact($0).utf8Prefix(256) }
        var fingerprint = ErrorFingerprint(source: event.source, template: template, topFrame: topFrame).hex
        var templateText = template
        if table[fingerprint] == nil, !admitNew(source: event.source, at: event.date) {
            templateText = "too many distinct errors from \(event.source)"
            event.topFrame = nil
            fingerprint = ErrorFingerprint(source: event.source, template: templateText, topFrame: nil).hex
        }
        let ms = Int64((event.date.timeIntervalSince1970 * 1000).rounded())
        let sample = redactor.redact(event.message).utf8Prefix(limits.maxMessageBytes)
        let context = boundedContext(event.context)
        if var entry = table[fingerprint] {
            entry.count &+= 1
            entry.level = max(entry.level, event.level)
            if ms >= entry.lastMs {
                entry.lastMs = ms
                entry.sample = sample
                entry.context = context
            }
            entry.firstMs = min(entry.firstMs, ms)
            table[fingerprint] = entry
        } else {
            table[fingerprint] = ErrorEntry(fingerprint: fingerprint, source: event.source, level: event.level,
                                            template: templateText, sample: sample,
                                            topFrame: topFrame,
                                            context: context, count: 1, firstMs: ms, lastMs: ms)
            evictIfNeeded()
        }
        dirty.insert(fingerprint)
    }

    private func admitNew(source: String, at date: Date) -> Bool {
        let minute = Int64(date.timeIntervalSince1970 / 60)
        var window = newFingerprints[source] ?? (minute, 0)
        if window.minute != minute { window = (minute, 0) }
        window.count += 1
        newFingerprints[source] = window
        return window.count <= limits.newFingerprintsPerMinute
    }

    private func boundedContext(_ context: [String: String]) -> [String: String] {
        var kept: [String: String] = [:]
        for key in context.keys.sorted().prefix(limits.maxContextKeys) {
            kept[key.utf8Prefix(64)] = redactor.redact(context[key] ?? "").utf8Prefix(limits.maxContextValueBytes)
        }
        return kept
    }

    private func evictIfNeeded() {
        guard table.count > limits.maxEntries else { return }
        // Drop a tenth at once so a full table does not sort on every new fingerprint.
        let excess = table.count - limits.maxEntries + max(1, limits.maxEntries / 10)
        for entry in table.values.sorted(by: { $0.lastMs < $1.lastMs }).prefix(excess) {
            table.removeValue(forKey: entry.fingerprint)
            dirty.remove(entry.fingerprint)
        }
    }

    private func scheduleFlush() {
        if dirty.count >= limits.flushBatch {
            flush()
            return
        }
        guard !dirty.isEmpty else { return }
        // A batching deadline that new records do not push back; flush() cancels it.
        flushTimer.scheduleIfIdle(after: .milliseconds(Int64(limits.flushDelaySeconds * 1000))) { [weak self] in
            await self?.flush()
        }
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
