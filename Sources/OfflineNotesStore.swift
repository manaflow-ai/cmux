import Foundation
import Network
import Observation

/// Lifecycle status of a captured offline note as it moves through the queue.
///
/// The three user-facing states called out in the feature request — pending,
/// sent, and failed — are surfaced directly; ``sending`` is a transient
/// in-flight state that collapses back to ``pending`` if the app is relaunched
/// mid-dispatch (see ``OfflineNotesStore``'s load normalization).
enum OfflineNoteStatus: String, Codable, Sendable, CaseIterable {
    /// Captured locally, waiting to be handed off to an agent (offline, or
    /// queued until the next flush).
    case pending
    /// Hand-off to an agent is in progress.
    case sending
    /// Successfully delivered to an agent.
    case sent
    /// Hand-off failed; the note is preserved and can be retried.
    case failed
}

/// A note captured by the user — typically while offline — and queued so cmux
/// can turn it into an agent task once connectivity is restored.
///
/// Notes are value types persisted as a JSON array so they survive app
/// restarts. Each note records enough state to render its status and support
/// retries without losing the original text.
struct OfflineNote: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var text: String
    var status: OfflineNoteStatus
    var createdAt: Date
    var updatedAt: Date
    /// When the note was successfully delivered to an agent.
    var sentAt: Date?
    /// Number of dispatch attempts so far (drives retry display / backoff).
    var attemptCount: Int
    /// Human-readable reason for the most recent failure, if any.
    var lastError: String?

    init(
        id: UUID = UUID(),
        text: String,
        status: OfflineNoteStatus = .pending,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sentAt: Date? = nil,
        attemptCount: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.text = text
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sentAt = sentAt
        self.attemptCount = attemptCount
        self.lastError = lastError
    }
}

/// Delivers a queued note to an agent. Conformers throw to mark the note
/// ``OfflineNoteStatus/failed`` (the note is preserved and retryable).
///
/// Modeling delivery as a seam keeps ``OfflineNotesStore`` fully testable (the
/// store is exercised against an in-memory fake) and lets the concrete agent
/// hand-off evolve independently of the queue semantics.
@MainActor
protocol OfflineNoteDispatching: AnyObject {
    func dispatch(_ note: OfflineNote) async throws
}

/// Failure reasons surfaced by the default dispatcher. `LocalizedError` so the
/// stored `lastError` reads cleanly in the notes list.
enum OfflineNoteDispatchError: LocalizedError, Equatable {
    /// No cmux window/workspace is available to receive the note.
    case noActiveWorkspace
    /// The active workspace has no focused agent surface to stage the note into.
    case noComposerTarget

    var errorDescription: String? {
        switch self {
        case .noActiveWorkspace:
            return String(
                localized: "offlineNotes.dispatch.error.noActiveWorkspace",
                defaultValue: "Open a cmux window to send this note to an agent."
            )
        case .noComposerTarget:
            return String(
                localized: "offlineNotes.dispatch.error.noComposerTarget",
                defaultValue: "Focus a terminal so cmux can send this note to its agent."
            )
        }
    }
}

/// Observes whether the machine currently has network connectivity and reports
/// changes. Abstracted behind a protocol so the store can be driven by a fake
/// in tests instead of the real `NWPathMonitor`.
@MainActor
protocol OfflineNotesReachabilityMonitoring: AnyObject {
    /// Best current knowledge of connectivity. Conservatively `false` until the
    /// first real reading arrives.
    var isOnline: Bool { get }
    /// Invoked on the main actor whenever connectivity changes.
    var onChange: (@MainActor (Bool) -> Void)? { get set }
    func start()
    func stop()
}

/// `NWPathMonitor`-backed reachability used in the running app.
@MainActor
final class OfflineNotesNetworkReachability: OfflineNotesReachabilityMonitoring {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.cmux.offline-notes.reachability")
    private var started = false
    private var hasDeliveredInitial = false

    /// Pessimistic until the monitor delivers its first path so we never claim
    /// online before it is proven.
    private(set) var isOnline: Bool = false
    var onChange: (@MainActor (Bool) -> Void)?

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let changed = self.isOnline != online || !self.hasDeliveredInitial
                self.isOnline = online
                self.hasDeliveredInitial = true
                if changed {
                    self.onChange?(online)
                }
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}

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
    static let shared = OfflineNotesStore()

    /// Captured notes, newest last (capture order).
    private(set) var notes: [OfflineNote] = []
    /// Mirrors the injected reachability so the UI can show an online/offline hint.
    private(set) var isOnline: Bool = false

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let dispatcher: any OfflineNoteDispatching
    @ObservationIgnored private let reachability: any OfflineNotesReachabilityMonitoring
    @ObservationIgnored private var isFlushing = false
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var pendingSnapshot: [OfflineNote]?
    @ObservationIgnored private var persistTask: Task<Void, Never>?

    /// Bounds so the app-lifetime queue and its backing file stay finite: a note
    /// is truncated to ``maxNoteLength`` chars, at most ``maxRetainedSentNotes``
    /// sent notes are kept (oldest first), and the queue holds ``maxTotalNotes``
    /// total — past which ``addNote`` refuses new captures (never evicting unsent
    /// work) rather than growing unbounded.
    static let maxNoteLength = 100_000
    static let maxRetainedSentNotes = 200
    static let maxTotalNotes = 1_000

    init(
        fileURL: URL? = OfflineNotesStore.defaultFileURL(),
        dispatcher: any OfflineNoteDispatching = OfflineNoteAgentDispatcher(),
        reachability: any OfflineNotesReachabilityMonitoring = OfflineNotesNetworkReachability(),
        autostart: Bool = true
    ) {
        self.fileURL = fileURL
        self.dispatcher = dispatcher
        self.reachability = reachability
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

    // MARK: - Mutations

    /// Captures a new note. Whitespace-only input is ignored. Returns the stored
    /// note, or `nil` if nothing was captured.
    @discardableResult
    func addNote(_ text: String) -> OfflineNote? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Reclaim space from old sent notes first, then apply backpressure:
        // refuse the capture once the queue is full so pending/failed notes
        // cannot grow without bound. Existing unsent notes are preserved.
        pruneSentNotes()
        guard notes.count < Self.maxTotalNotes else { return nil }
        let capped = String(trimmed.prefix(Self.maxNoteLength))
        let note = OfflineNote(text: capped)
        notes.append(note)
        persist()
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
    /// Status transitions are applied in memory and persisted **once** when the
    /// pass finishes, so reconnecting with a large backlog performs a single
    /// coalesced write (off the main actor) rather than two writes per note. A
    /// status held only in memory if the app is killed mid-flush is recovered as
    /// ``OfflineNoteStatus/pending`` on next launch (see ``normalizedForLoad(_:)``),
    /// so the note is retried rather than lost.
    func flush() async {
        guard isOnline else { return }
        guard !isFlushing else { return }
        isFlushing = true
        defer {
            isFlushing = false
            pruneSentNotes()
            persist()
        }

        while isOnline, let index = notes.firstIndex(where: { $0.status == .pending }) {
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
            await persistAndWait()
        }
    }

    /// Persists the current queue and awaits the off-main write. Used inside
    /// ``flush()`` so each successful hand-off is durable before the next runs.
    private func persistAndWait() async {
        persist()
        await waitForPendingPersist()
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

    /// Evicts the oldest already-sent notes beyond ``maxRetainedSentNotes`` so
    /// the queue cannot grow without bound across the app's lifetime. Pending
    /// and failed notes are preserved. Does not persist on its own — callers
    /// persist after their mutation.
    private func pruneSentNotes() {
        let sentIDs = notes.filter { $0.status == .sent }.map(\.id)
        guard sentIDs.count > Self.maxRetainedSentNotes else { return }
        let evictCount = sentIDs.count - Self.maxRetainedSentNotes
        // `notes` is in capture order, so the leading sent ids are the oldest.
        let evicted = Set(sentIDs.prefix(evictCount))
        notes.removeAll { evicted.contains($0.id) }
    }

    /// Maps a dispatch failure to a fixed, localized message. Only our own
    /// ``OfflineNoteDispatchError`` text is surfaced; any other error (network,
    /// provider, etc.) is reduced to a generic message so raw upstream/internal
    /// strings never reach the notes UI. Detail stays in DEBUG diagnostics.
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

    /// Persists the current queue. Writes are coalesced and performed off the
    /// main actor: each call records the latest snapshot and a single drain task
    /// encodes + atomically writes the newest snapshot, so a burst of mutations
    /// (or a reconnect flush) never blocks the main actor on repeated disk I/O.
    private func persist() {
        guard let fileURL else { return }
        pendingSnapshot = notes
        guard persistTask == nil else { return }
        persistTask = Task { [weak self] in
            await self?.drainPersist(to: fileURL)
        }
    }

    private func drainPersist(to fileURL: URL) async {
        while let snapshot = pendingSnapshot {
            pendingSnapshot = nil
            await Self.writeToDisk(snapshot, to: fileURL)
        }
        persistTask = nil
    }

    /// Awaits any in-flight persistence. Useful for flushing queued writes
    /// before the app terminates, and lets tests observe a settled file.
    func waitForPendingPersist() async {
        await persistTask?.value
    }

    private nonisolated static func writeToDisk(_ notes: [OfflineNote], to fileURL: URL) async {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(notes)
            try data.write(to: fileURL, options: .atomic)
        } catch {
#if DEBUG
            cmuxDebugLog("offlineNotes.store.saveFailed error=\(error.localizedDescription)")
#endif
        }
    }

    private static func load(fileURL: URL?) -> [OfflineNote] {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([OfflineNote].self, from: data) else {
            return []
        }
        return decoded
    }

    nonisolated static func defaultFileURL(
        appSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        isRunningUnderAutomatedTests: Bool = SessionRestorePolicy.isRunningUnderAutomatedTests()
    ) -> URL? {
        guard !isRunningUnderAutomatedTests, let appSupportDirectory else { return nil }
        return appSupportDirectory
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("offline-notes.json", isDirectory: false)
    }

    nonisolated static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    nonisolated static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
