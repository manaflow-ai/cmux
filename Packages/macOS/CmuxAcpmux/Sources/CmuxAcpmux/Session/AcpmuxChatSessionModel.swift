import Foundation
import Observation

/// The state of one chat pane: its daemon connection, the selected session, and the
/// folded transcript.
///
/// The model owns reconnection. After the connection drops it reconnects with backoff
/// and re-attaches with `afterSeq` set to the last applied record, so nothing is lost
/// and nothing renders twice. Transcript changes are signalled through
/// ``transcriptRevision`` and ``onTranscriptChanged``; a view diffs ``rows`` by id and
/// version on its own frame clock.
@MainActor
@Observable
public final class AcpmuxChatSessionModel {
    /// Connection progress.
    public enum ConnectionState: Sendable, Equatable {
        /// Connecting or starting the daemon.
        case connecting
        /// Connected and initialized.
        case connected
        /// The last attempt failed; the model retries after a delay.
        case failed(String)
    }

    /// Connection progress.
    public private(set) var connectionState: ConnectionState = .connecting
    /// Every session the daemon knows, newest first.
    public private(set) var sessions: [AcpmuxSessionSummary] = []
    /// The selected session id.
    public private(set) var sessionId: String?
    /// Harness and model choices.
    public private(set) var catalog = AcpmuxHarnessCatalog()
    /// Whether an older history page is loading.
    public private(set) var isLoadingOlder = false
    /// Increases on every transcript change.
    public private(set) var transcriptRevision = 0
    /// Called on the main actor after the transcript changes.
    @ObservationIgnored public var onTranscriptChanged: (() -> Void)?
    /// Called when the selected session id changes, so the owner can persist it.
    @ObservationIgnored public var onSessionIdChanged: ((String?) -> Void)?

    @ObservationIgnored private var reducer = TranscriptReducer()
    @ObservationIgnored private var api: (any AcpmuxSessionAPI)?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var historyExhausted = false
    private let connector: any AcpmuxConnecting
    private let clock: any Clock<Duration>
    private let defaultWorkingDirectory: String?
    private let now: @Sendable () -> Date
    /// Newest records requested on attach. Older pages load on demand.
    public let attachLimit: Int
    /// Records requested per older page.
    public let pageSize: Int

    /// Creates a model. Call ``start()`` to connect.
    /// - Parameters:
    ///   - connector: Opens the daemon connection.
    ///   - sessionId: A session to reopen, for example from a restored snapshot.
    ///   - workingDirectory: `cwd` for new sessions.
    ///   - clock: Drives reconnect backoff; tests pass a manual clock.
    ///   - now: Timestamp source for local echoes.
    ///   - attachLimit: Records fetched on attach. 400 fills several screens without a long first decode.
    ///   - pageSize: Records fetched per older page.
    public init(
        connector: any AcpmuxConnecting,
        sessionId: String?,
        workingDirectory: String?,
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = { Date() },
        attachLimit: Int = 400,
        pageSize: Int = 400
    ) {
        self.connector = connector
        self.sessionId = sessionId
        self.defaultWorkingDirectory = workingDirectory
        self.clock = clock
        self.now = now
        self.attachLimit = attachLimit
        self.pageSize = pageSize
    }

    // MARK: - Derived state

    /// Rendered transcript rows, oldest first.
    public var rows: [TranscriptRow] { reducer.rows }

    /// The selected session's summary.
    public var summary: AcpmuxSessionSummary? {
        guard let sessionId else { return nil }
        return sessions.first { $0.sessionId == sessionId }
    }

    /// Whether the agent is working on a turn.
    public var isWorking: Bool {
        _ = transcriptRevision
        return reducer.isTurnOpen || summary?.isWorking == true
    }

    /// Prompts waiting behind the running turn.
    public var queue: [AcpmuxQueueEntry] {
        _ = transcriptRevision
        return reducer.queue
    }

    /// The oldest permission request that still waits for a decision.
    public var pendingPermission: TranscriptPermissionCard? {
        _ = transcriptRevision
        for row in reducer.rows {
            if case .permission(let card) = row.content, card.isPending { return card }
        }
        return nil
    }

    /// Whether older history may exist above the loaded rows.
    public var canLoadOlder: Bool {
        guard let first = reducer.firstSeq else { return false }
        return first > 1 && !historyExhausted
    }

    // MARK: - Lifecycle

    /// Connects and keeps the connection alive until ``stop()``.
    public func start() {
        guard connectionTask == nil else { return }
        connectionTask = Task { [weak self] in
            await self?.runConnectionLoop()
        }
    }

    /// Disconnects and stops reconnecting.
    public func stop() {
        connectionTask?.cancel()
        connectionTask = nil
        let api = api
        self.api = nil
        Task { await api?.close() }
    }

    private func runConnectionLoop() async {
        var delay = Duration.milliseconds(250)
        while !Task.isCancelled {
            connectionState = .connecting
            do {
                let api = try await connector.connect()
                self.api = api
                sessions = sortSessions(try await api.watch())
                connectionState = .connected
                delay = .milliseconds(250)
                Task { [weak self] in await self?.refreshCatalog() }
                if let sessionId {
                    try await attach(sessionId, api: api, resume: true)
                }
                for await notification in api.notifications {
                    handle(notification)
                }
                self.api = nil
            } catch is CancellationError {
                return
            } catch {
                self.api = nil
                connectionState = .failed(String(describing: error))
            }
            guard !Task.isCancelled else { return }
            // Reconnect backoff is a genuine delay between attempts, capped at 5 s.
            try? await clock.sleep(for: delay)
            delay = min(delay * 2, .seconds(5))
        }
    }

    private func refreshCatalog() async {
        guard let api, let catalog = try? await api.harnessCatalog() else { return }
        self.catalog = catalog
    }

    // MARK: - Session selection

    /// Switches the pane to another session.
    public func select(sessionId newSessionId: String) async {
        guard newSessionId != sessionId else { return }
        if let old = sessionId, let api { try? await api.detach(sessionId: old) }
        sessionId = newSessionId
        onSessionIdChanged?(newSessionId)
        resetTranscript()
        guard let api else { return }
        try? await attach(newSessionId, api: api, resume: false)
    }

    /// Creates a session on `harness` and selects it.
    /// - Returns: The new session id, or `nil` when creation failed.
    @discardableResult
    public func createSession(harness: String?) async -> String? {
        guard let api else { return nil }
        do {
            let newId = try await api.newSession(harness: harness, cwd: defaultWorkingDirectory)
            if let refreshed = try? await api.watch() { sessions = sortSessions(refreshed) }
            await select(sessionId: newId)
            return newId
        } catch {
            connectionState = .failed(String(describing: error))
            return nil
        }
    }

    private func attach(_ id: String, api: any AcpmuxSessionAPI, resume: Bool) async throws {
        let afterSeq = resume && reducer.lastSeq > 0 ? reducer.lastSeq : nil
        let result = try await api.attach(sessionId: id, afterSeq: afterSeq, limit: attachLimit)
        guard id == sessionId else { return }
        upsert(result.session.summary)
        reducer.apply(result.events)
        reducer.replaceQueue(result.session.queue)
        if afterSeq == nil, result.events.count < attachLimit {
            historyExhausted = true
        }
        transcriptDidChange()
    }

    private func resetTranscript() {
        reducer = TranscriptReducer()
        historyExhausted = false
        transcriptDidChange()
    }

    /// Loads one older page of history.
    public func loadOlder() async {
        guard let api, let sessionId, canLoadOlder, !isLoadingOlder, let first = reducer.firstSeq else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        let afterSeq = max(0, first - 1 - pageSize)
        guard let older = try? await api.events(sessionId: sessionId, afterSeq: afterSeq, limit: first - 1 - afterSeq),
              sessionId == self.sessionId else { return }
        if older.isEmpty || afterSeq == 0 { historyExhausted = true }
        reducer.prepend(older)
        transcriptDidChange()
    }

    // MARK: - Actions

    /// Sends a prompt. While a turn runs the prompt queues until the turn ends.
    ///
    /// - Returns: The transcript row id of the local echo when one was shown immediately,
    ///   so a view can animate the composer text into it; `nil` when the prompt queued or
    ///   a session must be created first.
    @discardableResult
    public func send(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let promptId = UUID().uuidString.lowercased()
        let echoNow = sessionId != nil && api != nil && !isWorking
        if echoNow { addLocalEcho(promptId: promptId, text: trimmed) }
        Task { [weak self] in await self?.sendPrompt(trimmed, promptId: promptId, echoed: echoNow) }
        return echoNow ? TranscriptReducer.userRowID(promptId: promptId, seq: 0) : nil
    }

    /// The harness used when a prompt creates a new session.
    public var newSessionHarness: String?

    private func addLocalEcho(promptId: String, text: String) {
        reducer.addPendingUserMessage(promptId: promptId, text: text, at: Int64(now().timeIntervalSince1970 * 1000))
        transcriptDidChange()
    }

    private func sendPrompt(_ text: String, promptId: String, echoed: Bool) async {
        var echoed = echoed
        if sessionId == nil {
            guard await createSession(harness: newSessionHarness ?? catalog.defaultHarness) != nil else { return }
            addLocalEcho(promptId: promptId, text: text)
            echoed = true
        }
        guard let api, let sessionId else { return }
        let queueBehindTurn = !echoed
        do {
            _ = try await api.prompt(
                sessionId: sessionId,
                text: text,
                promptId: promptId,
                delivery: queueBehindTurn ? "turn" : nil
            )
        } catch JSONRPCClientError.disconnected {
            // The turn continues in the daemon; reconnect re-attaches and shows its outcome.
        } catch {
            reducer.markPendingUserMessageFailed(promptId: promptId)
            transcriptDidChange()
        }
    }

    /// Sends an undelivered message again, replacing its failed bubble.
    public func retryUndelivered(rowID: String) {
        guard let text = reducer.takeFailedMessage(rowID: rowID) else { return }
        transcriptDidChange()
        send(text)
    }

    /// Cancels the running turn.
    public func cancelTurn() {
        guard let api, let sessionId, isWorking else { return }
        Task { try? await api.cancel(sessionId: sessionId) }
    }

    /// Answers a permission request. A `nil` option cancels it.
    public func respond(to card: TranscriptPermissionCard, optionId: String?) {
        guard let api, let sessionId else { return }
        Task { try? await api.respondToPermission(sessionId: sessionId, permissionId: card.permissionId, optionId: optionId) }
    }

    /// Delivers a queued prompt into the running turn now.
    public func steer(_ entry: AcpmuxQueueEntry) {
        guard let api, let sessionId else { return }
        Task { try? await api.steerQueued(sessionId: sessionId, promptId: entry.promptId) }
    }

    /// Removes a queued prompt.
    public func removeQueued(_ entry: AcpmuxQueueEntry) {
        guard let api, let sessionId else { return }
        Task { try? await api.removeQueued(sessionId: sessionId, promptId: entry.promptId) }
    }

    /// Switches the session's model.
    public func setModel(_ modelId: String) {
        guard let api, let sessionId else { return }
        Task { try? await api.setModel(sessionId: sessionId, modelId: modelId) }
    }

    // MARK: - Notifications

    private func handle(_ notification: JSONRPCNotification) {
        switch notification.method {
        case "session/update":
            guard notification.params["sessionId"]?.stringValue == sessionId,
                  let record = AcpmuxEventRecord(liveSessionUpdate: notification.params) else { return }
            applyLive(record)
        case "_acpmux/event":
            guard notification.params["sessionId"]?.stringValue == sessionId,
                  let record = AcpmuxEventRecord(liveMuxEvent: notification.params) else { return }
            applyLive(record)
        case "_acpmux/session_changed":
            guard let session = notification.params["session"], let summary = Self.decodeSummary(session) else { return }
            if notification.params["kind"]?.stringValue == "purged" {
                sessions.removeAll { $0.sessionId == summary.sessionId }
            } else {
                upsert(summary)
            }
        case "_acpmux/lagged":
            Task { [weak self] in await self?.resync() }
        default:
            break
        }
    }

    private func applyLive(_ record: AcpmuxEventRecord) {
        // Live delivery skips `out` and response records, so sequence gaps are normal;
        // real loss is reported by `_acpmux/lagged`.
        reducer.apply(record)
        transcriptDidChange()
    }

    private func resync() async {
        guard let api, let sessionId else { return }
        guard let records = try? await api.events(sessionId: sessionId, afterSeq: reducer.lastSeq, limit: 5_000),
              sessionId == self.sessionId else { return }
        reducer.apply(records)
        transcriptDidChange()
    }

    private func upsert(_ summary: AcpmuxSessionSummary) {
        if let index = sessions.firstIndex(where: { $0.sessionId == summary.sessionId }) {
            sessions[index] = summary
        } else {
            sessions.append(summary)
        }
        sessions = sortSessions(sessions)
    }

    private func sortSessions(_ list: [AcpmuxSessionSummary]) -> [AcpmuxSessionSummary] {
        list.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
    }

    private func transcriptDidChange() {
        transcriptRevision += 1
        onTranscriptChanged?()
    }

    private static func decodeSummary(_ value: JSONValue) -> AcpmuxSessionSummary? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(AcpmuxSessionSummary.self, from: data)
    }
}
