import Foundation
import Observation

/// Persisted queue of user-captured notes that become agent tasks once the
/// machine is back online.
///
/// Responsibilities:
/// - Capture notes locally and persist them (survives app restarts).
/// - Track each note's status (pending / sending / sent / failed).
/// - Drain pending notes through an ``OfflineNoteDispatching`` seam whenever
///   connectivity is (re)gained, plus on explicit user request.
///
/// State is `@Observable` (no Combine) and connectivity plus the agent hand-off
/// are injected, so the queue logic is exercised deterministically in tests.
/// The single app-wide instance is ``shared`` (one queue ⇒ one backing file);
/// it is created lazily the first time the Notes panel is opened.
@MainActor
@Observable
final class OfflineNotesStore {
    /// Created lazily the first time the Notes panel is opened. In production the
    /// store is only ever constructed via this accessor, and its ``init`` flips
    /// ``hasInstance`` to `true`, so quit-time durability can be gated on "the
    /// store was actually used this session" rather than the live beta toggle —
    /// without force-creating the store (and its backing file) for users who
    /// never opened Notes.
    static let shared = OfflineNotesStore()

    /// Whether the store has been instantiated this session (set from ``init``).
    /// Read from the app terminate hook to decide whether a final durable persist
    /// is needed, decoupling quit durability from the current beta-feature
    /// toggle. In production the store is only built via ``shared``, so this
    /// becomes `true` exactly when Notes is first used.
    private(set) static var hasInstance = false

    /// Captured notes, newest last (capture order).
    private(set) var notes: [OfflineNote] = []
    /// Mirrors the injected reachability so the UI can show an online/offline hint.
    private(set) var isOnline: Bool = false

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let dispatcher: any OfflineNoteDispatching
    @ObservationIgnored private let reachability: any OfflineNotesReachabilityMonitoring
    @ObservationIgnored private var isFlushing = false
    @ObservationIgnored private var hasStarted = false
    // Ordered I/O executor for disk writes; `notes` remains @MainActor-isolated.
    // A blocking termination enqueue preserves the final-write ordering that an
    // actor cannot provide from `applicationWillTerminate`.
    @ObservationIgnored private let writeQueue = DispatchQueue(label: "com.cmux.offline-notes.persist")

    /// Bounds so the queue and its backing file stay small enough that the
    /// synchronous capture write is cheap on the main actor: a note is truncated
    /// to ``maxNoteLength`` Unicode scalars, at most ``maxRetainedSentNotes`` sent
    /// notes are kept (oldest first), and the queue holds ``maxTotalNotes`` total —
    /// past which ``addNote`` refuses new captures (never evicting unsent work).
    /// The cap counts Unicode scalars rather than `Character`s deliberately: a
    /// single grapheme cluster can contain unboundedly many combining scalars, so
    /// a `Character`-based cap would not bound the persisted byte size (a pasted
    /// "Zalgo"/combining-mark blob could stay arbitrarily large and be re-encoded
    /// on every persist). Capping scalars bounds each note to ≤ 4 ×
    /// ``maxNoteLength`` UTF-8 bytes, so the worst-case file is ≤ 4 ×
    /// ``maxNoteLength`` × ``maxTotalNotes`` bytes (a few MB), and typically a few
    /// KB. See ``boundedNoteText(_:)``.
    static let maxNoteLength = 4_000
    static let maxRetainedSentNotes = 100
    static let maxTotalNotes = 200

    /// Hard ceiling on the persisted file the load path reads: the legitimate
    /// worst case (``maxTotalNotes`` × ~4×``maxNoteLength`` bytes) is a few MB, so a
    /// larger file is corrupt/hand-edited and is skipped before decode balloons memory.
    static let maxPersistedFileBytes = 32 * 1024 * 1024

    /// `dispatcher` and `reachability` default to `nil` and are constructed in
    /// the body rather than as default arguments: their concrete types are
    /// `@MainActor`-isolated, and default-argument expressions are evaluated in a
    /// nonisolated context, so building them here (the init is `@MainActor`)
    /// avoids a main-actor-isolation error. Tests inject fakes.
    init(
        fileURL: URL? = OfflineNotesStore.defaultFileURL(),
        dispatcher: (any OfflineNoteDispatching)? = nil,
        reachability: (any OfflineNotesReachabilityMonitoring)? = nil,
        autostart: Bool = true
    ) {
        // Record that the store exists this session (a static flag, so this is
        // valid before `self` is fully initialized). The terminate hook reads it
        // to fire quit-time durability independently of the live beta toggle; in
        // production the store is only constructed via `shared`.
        Self.hasInstance = true
        self.fileURL = fileURL
        self.dispatcher = dispatcher ?? OfflineNoteAgentDispatcher()
        self.reachability = reachability ?? OfflineNotesNetworkReachability()
        self.notes = Self.normalizedForLoad(Self.load(fileURL: fileURL))
        if autostart {
            start()
        }
    }

    // MARK: - Lifecycle

    /// Begins connectivity monitoring. Idempotent. Flushes immediately if we are
    /// already online so notes left pending from a previous offline session are
    /// delivered once the app relaunches with a connection.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        isOnline = reachability.isOnline
        reachability.onChange = { [weak self] online in
            self?.handleReachabilityChange(online)
        }
        reachability.start()
        if isOnline {
            scheduleFlush()
        }
    }

    private func handleReachabilityChange(_ online: Bool) {
        let regainedConnectivity = online && !isOnline
        isOnline = online
        if regainedConnectivity {
            scheduleFlush()
        }
    }

    /// Shared trigger for "the set of deliverable workspaces may have changed"
    /// events — app reactivation and workspace selection. A note is delivered
    /// only when its captured workspace is the visible selection, so selecting a
    /// workspace (or reactivating the app) is exactly when notes deferred while
    /// that workspace was backgrounded should be retried.
    ///
    /// Beta-gated (the flag defaults off), so for users without the Notes
    /// feature this returns *before* touching the shared store; the flush itself
    /// is a no-op when offline, not yet started, or nothing is pending. Cheap
    /// enough to call from the workspace-selection path.
    @MainActor
    static func flushIfFeatureEnabled() {
        guard RightSidebarBetaFeatureSettings.isNotesEnabled() else { return }
        Task { await OfflineNotesStore.shared.flush() }
    }

    // MARK: - Mutations

    /// Captures a new note. Whitespace-only input is ignored. Returns the stored
    /// note, or `nil` if nothing was captured.
    @discardableResult
    func addNote(_ text: String, workspaceID: UUID? = nil) -> OfflineNote? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Reclaim space from old sent notes first, then apply backpressure:
        // refuse the capture once the queue is full so pending/failed notes
        // cannot grow without bound. Existing unsent notes are preserved.
        pruneSentNotes()
        guard notes.count < Self.maxTotalNotes else { return nil }
        let capped = Self.boundedNoteText(trimmed)
        let note = OfflineNote(text: capped, workspaceID: workspaceID)
        notes.append(note)
        persist()
        // Already online → hand off now (the `isFlushing` guard prevents duplicates).
        scheduleFlush()
        return note
    }

    /// Removes a note from the queue.
    func deleteNote(id: UUID) {
        let before = notes.count
        notes.removeAll { $0.id == id }
        guard notes.count != before else { return }
        persist()
    }

    /// Drops every successfully-sent note.
    func clearSent() {
        let before = notes.count
        notes.removeAll { $0.status == .sent }
        guard notes.count != before else { return }
        persist()
    }

    /// Returns a previously-failed note to the pending state so it is retried on
    /// the next flush.
    func retry(id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        guard notes[index].status == .failed else { return }
        notes[index].status = .pending
        notes[index].lastError = nil
        notes[index].updatedAt = Date()
        persist()
        scheduleFlush()
    }

    /// Re-queues every failed note.
    func retryAllFailed() {
        var changed = false
        for index in notes.indices where notes[index].status == .failed {
            notes[index].status = .pending
            notes[index].lastError = nil
            notes[index].updatedAt = Date()
            changed = true
        }
        if changed {
            persist()
            scheduleFlush()
        }
    }

    // MARK: - Counts (for UI)

    var pendingCount: Int { notes.lazy.filter { $0.status == .pending || $0.status == .sending }.count }
    var failedCount: Int { notes.lazy.filter { $0.status == .failed }.count }
    var sentCount: Int { notes.lazy.filter { $0.status == .sent }.count }

    // MARK: - Flush

    private func scheduleFlush() {
        Task { await flush() }
    }

    /// Delivers every pending note to an agent, oldest first, one at a time.
    ///
    /// No-ops while offline or when another flush is already running. Failed
    /// notes are left in the ``OfflineNoteStatus/failed`` state (not retried in
    /// the same pass) so a persistently-failing dispatcher cannot spin.
    ///
    /// Each note's terminal state is persisted (off the main actor, awaited via
    /// ``waitForPendingPersist()``) before the next note is dispatched, so a crash
    /// mid-flush can't replay a note that was already staged. The transient
    /// ``OfflineNoteStatus/sending`` state is not persisted; it is recovered as
    /// ``OfflineNoteStatus/pending`` on next launch (see ``normalizedForLoad(_:)``).
    func flush() async {
        guard isOnline else { return }
        guard !isFlushing else { return }
        isFlushing = true
        defer {
            isFlushing = false
            pruneSentNotes()
            persist()
        }

        // Notes deferred this pass (their target workspace isn't visible yet) are
        // skipped so they don't block deliverable notes, and excluded from
        // re-selection so the loop can't spin.
        var deferred = Set<UUID>()
        while isOnline, let index = notes.firstIndex(where: { $0.status == .pending && !deferred.contains($0.id) }) {
            var note = notes[index]
            note.status = .sending
            note.attemptCount += 1
            note.updatedAt = Date()
            applyInMemory(note)

            do {
                try await dispatcher.dispatch(note)
                if var delivered = self.note(id: note.id) {
                    delivered.status = .sent
                    delivered.sentAt = Date()
                    delivered.lastError = nil
                    delivered.updatedAt = Date()
                    applyInMemory(delivered)
                }
            } catch OfflineNoteDispatchError.noActiveWorkspace {
                // The note's captured workspace isn't deliverable-and-visible right
                // now — no window yet at launch, the workspace was closed, or the
                // user switched away. This is transient: revert to pending, defer
                // it this pass, and keep trying other notes. A later flush
                // (app activation, reselecting the workspace, reconnect, or opening
                // Notes) retries it. Notes are never stranded as failed.
                if var deferredNote = self.note(id: note.id) {
                    deferredNote.status = .pending
                    deferredNote.attemptCount = max(0, deferredNote.attemptCount - 1)
                    deferredNote.updatedAt = Date()
                    applyInMemory(deferredNote)
                }
                deferred.insert(note.id)
                continue
            } catch {
#if DEBUG
                cmuxDebugLog("offlineNotes.dispatch.failed error=\(error.localizedDescription)")
#endif
                if var failed = self.note(id: note.id) {
                    failed.status = .failed
                    failed.lastError = Self.userFacingFailureMessage(for: error)
                    failed.updatedAt = Date()
                    applyInMemory(failed)
                }
            }
            // Durably record this note's terminal state (off the main actor)
            // before dispatching the next one, so a crash can't replay a note
            // that was already staged into the composer.
            persist()
            await waitForPendingPersist()
        }
    }

    // MARK: - Internal helpers

    private func note(id: UUID) -> OfflineNote? {
        notes.first { $0.id == id }
    }

    /// Replaces a note by id in memory only (the array may have mutated across
    /// an `await`). Callers persist separately so a flush can coalesce writes.
    private func applyInMemory(_ note: OfflineNote) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index] = note
    }

    /// Evicts the oldest already-sent notes beyond ``maxRetainedSentNotes`` so the
    /// queue stays bounded; pending/failed are preserved. Callers persist.
    private func pruneSentNotes() {
        notes = Self.prunedSentNotes(notes)
    }

    /// Pure form of the sent-note eviction shared by the live mutation path
    /// (``pruneSentNotes()``) and load-time bounding (``boundedForLoad(_:)``).
    /// `notes` is capture-ordered, so the leading sent ids are the oldest — evicted first.
    private static func prunedSentNotes(_ notes: [OfflineNote]) -> [OfflineNote] {
        let sentIDs = notes.filter { $0.status == .sent }.map(\.id)
        guard sentIDs.count > maxRetainedSentNotes else { return notes }
        let evicted = Set(sentIDs.prefix(sentIDs.count - maxRetainedSentNotes))
        return notes.filter { !evicted.contains($0.id) }
    }

    /// Maps a failure to a fixed message: only our own ``OfflineNoteDispatchError``
    /// text is surfaced; any other error collapses to a generic one (no raw upstream
    /// text reaches the UI). Detail stays in DEBUG diagnostics.
    private static func userFacingFailureMessage(for error: Error) -> String {
        if let dispatchError = error as? OfflineNoteDispatchError,
           let description = dispatchError.errorDescription {
            return description
        }
        return String(
            localized: "offlineNotes.dispatch.error.generic",
            defaultValue: "Couldn't send this note to an agent. It will stay queued for retry."
        )
    }

    // MARK: - Persistence

    /// Collapses any `.sending` notes left behind by a crash/relaunch back to
    /// `.pending` so they are retried rather than stranded mid-flight.
    private static func normalizedForLoad(_ notes: [OfflineNote]) -> [OfflineNote] {
        notes.map { note in
            guard note.status == .sending else { return note }
            var fixed = note
            fixed.status = .pending
            return fixed
        }
    }

    /// Restores the queue's size bounds on load, mirroring the write path: evict
    /// the oldest `.sent` notes beyond ``maxRetainedSentNotes``, then, if still over
    /// ``maxTotalNotes``, keep the newest captures (array is capture-ordered). Without
    /// this a corrupt/hand-edited file with more notes than the caps would put an
    /// unbounded queue into the store — unbounded rows, O(n) scans, full-array rewrites.
    private static func boundedForLoad(_ notes: [OfflineNote]) -> [OfflineNote] {
        let pruned = prunedSentNotes(notes)
        guard pruned.count > maxTotalNotes else { return pruned }
        return Array(pruned.suffix(maxTotalNotes))
    }

    /// Enqueues a write of the current queue onto the serial ``writeQueue``. The
    /// main actor only snapshots `notes` (O(1) COW) and dispatches; the write
    /// runs off the main actor. Because the queue is serial, writes apply in
    /// enqueue order so the newest snapshot is always the last to land. Quit
    /// durability is guaranteed by ``flushPendingPersistOnTermination()``.
    private func persist() {
        guard let fileURL else { return }
        let snapshot = notes
        writeQueue.async { OfflineNotesStore.writeToDisk(snapshot, to: fileURL) }
    }

    /// Awaits all writes enqueued so far. Used by ``flush()`` so each hand-off is
    /// durable before the next note is dispatched. Returns immediately when no
    /// writes are pending (e.g. tests with no backing file).
    func waitForPendingPersist() async {
        await withCheckedContinuation { continuation in
            writeQueue.async { continuation.resume() }
        }
    }

    /// Synchronously writes the current queue as the **final** write on the
    /// serial queue. Called from `applicationWillTerminate` so a freshly-captured
    /// note whose async write has not landed yet is durable on quit; being last
    /// in the serial order, it cannot be overwritten by an earlier async write.
    func flushPendingPersistOnTermination() {
        guard let fileURL else { return }
        let snapshot = notes
        // Termination-only ordered I/O drain; `notes` was snapshotted above.
        writeQueue.asyncAndWait { OfflineNotesStore.writeToDisk(snapshot, to: fileURL) }
    }

    private nonisolated static func writeToDisk(_ notes: [OfflineNote], to fileURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try makeEncoder().encode(notes)
            try data.write(to: fileURL, options: .atomic)
        } catch {
#if DEBUG
            cmuxDebugLog("offlineNotes.store.saveFailed error=\(error.localizedDescription)")
#endif
        }
    }

    /// Bounds `text` to ``maxNoteLength`` Unicode scalars, truncating on a scalar
    /// boundary (so the result is always valid UTF-8). Capping scalars — not
    /// `Character`s — is what bounds the persisted byte size: a single grapheme
    /// cluster can hold unboundedly many combining scalars, so a `Character`-based
    /// `prefix` would leave the encoded note (and every subsequent rewrite of the
    /// queue file) arbitrarily large. `count`/`index(_:offsetBy:)` walk the string
    /// once; `addNote`/`load` are not hot paths, so the O(n) scan is fine.
    static func boundedNoteText(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count > maxNoteLength else { return text }
        let end = scalars.index(scalars.startIndex, offsetBy: maxNoteLength)
        return String(text[..<end])
    }

    /// Whether a persisted file of `byteCount` bytes is small enough to read on
    /// load (see ``maxPersistedFileBytes``); pure so the ceiling is unit-testable.
    static func persistedFileIsReadable(byteCount: Int) -> Bool {
        byteCount <= maxPersistedFileBytes
    }

    private static func load(fileURL: URL?) -> [OfflineNote] {
        guard let fileURL else { return [] }
        // Skip a pathologically large file before reading it (a stat is far
        // cheaper): decode of a corrupt/hand-edited file would balloon memory
        // before the queue-size bounds below could trim it.
        if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           !persistedFileIsReadable(byteCount: fileSize) {
#if DEBUG
            cmuxDebugLog("offlineNotes.store.loadSkipped reason=fileTooLarge bytes=\(fileSize)")
#endif
            return []
        }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? makeDecoder().decode([OfflineNote].self, from: data) else {
            return []
        }
        // Re-apply the per-note length cap: a file written by an older build (or
        // hand-edited) could contain an over-long note, and we must not let it
        // reappear unbounded and then be re-encoded on every subsequent persist.
        let capped = decoded.map { note -> OfflineNote in
            var note = note
            note.text = boundedNoteText(note.text)
            return note
        }
        // Restore the queue-size bounds (see ``boundedForLoad(_:)``).
        return boundedForLoad(capped)
    }

    nonisolated static func defaultFileURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        isRunningUnderAutomatedTests: Bool = SessionRestorePolicy.isRunningUnderAutomatedTests()
    ) -> URL? {
        guard !isRunningUnderAutomatedTests, let appSupportDirectory else { return nil }
        // Scope the queue file by bundle identifier so production, staging, and
        // tagged side-by-side debug builds never share one file. Each variant is a
        // separate process with its own store and serial write queue; a shared file
        // would make concurrent captures last-writer-wins (dropping the other app's
        // notes) and expose one variant's queued note text in another. Mirrors
        // ``ClosedItemHistory`` and the session-restore persistence pattern.
        let bundleId = (bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? bundleIdentifier!
            : "com.cmuxterm.app"
        let safeBundleId = bundleId.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        return appSupportDirectory
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("offline-notes-\(safeBundleId).json", isDirectory: false)
    }

    // Encoders/decoders are created fresh per call: `JSONEncoder`/`JSONDecoder`
    // are mutable Foundation reference types, so a per-write instance avoids any
    // shared mutable state (the writes are also serialized on `writeQueue`).
    nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
