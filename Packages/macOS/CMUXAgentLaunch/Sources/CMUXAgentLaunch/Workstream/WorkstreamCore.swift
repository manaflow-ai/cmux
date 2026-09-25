import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Size of the in-memory ring buffer. Older items are evicted to disk-only.
public let WorkstreamDefaultRingCapacity = 2_000
public let WorkstreamDefaultInitialLoadLimit = 300
public let WorkstreamDefaultHistoryPageSize = 300

/// Actor-owned canonical Feed state and ingestion pipeline.
///
/// One instance per cmux process. The actor owns decoding, indexing,
/// persistence, and action ordering; the UI observes immutable snapshots.
public actor WorkstreamCore {
    public private(set) var items: [WorkstreamItem] = []
    public private(set) var pendingCount = 0
    public private(set) var actionableCount = 0
    public private(set) var hasMorePersistedItems = false
    public private(set) var isLoadingOlderItems = false

    public var pending: [WorkstreamItem] {
        items.filter { $0.status.isPending }
    }

    public var actionable: [WorkstreamItem] {
        items.filter { $0.kind.isActionable }
    }

    private let transport: any WorkstreamTransport
    private let persistence: WorkstreamPersistence?
    private let ringCapacity: Int
    private let initialLoadLimit: Int
    private let historyPageSize: Int
    private let clock: @Sendable () -> Date
    private let titleProvider: @Sendable (WorkstreamEvent) -> String?
    /// App-owned migration hook for versioned workstream identities.
    let workstreamIDNormalizer: @Sendable (String, String) -> String
    private var oldestLoadedPersistenceOffset: UInt64?

    /// Last known conversational context for each workstream. Tool hooks
    /// usually arrive without the surrounding user prompt, so the store
    /// carries forward prompt/preamble context from nearby telemetry rows.
    private var lastContextByWorkstream: [String: WorkstreamContext] = [:]
    private var snapshotContinuations: [UUID: AsyncStream<WorkstreamStoreSnapshot>.Continuation] = [:]
    private var snapshotTask: Task<Void, Never>?

    /// Creates the canonical Feed state for WorkstreamStore's projection.
    ///
    /// - Parameters:
    ///   - transport: Source and reply transport for live Feed events.
    ///   - persistence: Optional JSONL persistence for event history.
    ///   - ringCapacity: Maximum in-memory item count.
    ///   - initialLoadLimit: Maximum persisted item count loaded at startup.
    ///   - historyPageSize: Page size for older persisted history.
    ///   - clock: Clock used for timestamps and expiry checks.
    ///   - workstreamIDNormalizer: Optional migration for legacy ids loaded
    ///     from persistence or received from a producer. The second argument
    ///     is the raw producer identity, including registered agents not yet
    ///     represented by ``WorkstreamSource``.
    ///   - titleProvider: App boundary hook for localized display titles.
    public init(
        transport: any WorkstreamTransport = NullWorkstreamTransport(),
        persistence: WorkstreamPersistence? = nil,
        ringCapacity: Int = WorkstreamDefaultRingCapacity,
        initialLoadLimit: Int = WorkstreamDefaultInitialLoadLimit,
        historyPageSize: Int = WorkstreamDefaultHistoryPageSize,
        clock: @escaping @Sendable () -> Date = { Date() },
        workstreamIDNormalizer: @escaping @Sendable (String, String) -> String = { rawValue, _ in
            rawValue
        },
        titleProvider: @escaping @Sendable (WorkstreamEvent) -> String? = { _ in nil }
    ) {
        self.transport = transport
        self.persistence = persistence
        self.ringCapacity = ringCapacity
        self.initialLoadLimit = initialLoadLimit
        self.historyPageSize = historyPageSize
        self.clock = clock
        self.titleProvider = titleProvider
        self.workstreamIDNormalizer = workstreamIDNormalizer
    }

    public func start() async {
        if let persistence {
            if let page = try? await persistence.loadPage(limit: min(initialLoadLimit, ringCapacity)) {
                items = page.items.map(normalizedWorkstreamItem)
                recomputeCounts()
                hasMorePersistedItems = page.hasMoreBefore
                oldestLoadedPersistenceOffset = page.startOffset
                rebuildContextIndex()
            }
        }
        do {
            try await transport.subscribe { [weak self] event in
                guard let self else { return }
                Task { [weak self] in
                    await self?.ingest(event)
                }
            }
        } catch {
            // Transport failures are non-fatal; the store stays usable for
            // locally-injected items and tests.
        }
        publishSnapshot()
    }

    /// Returns the current immutable projection for synchronous UI reads.
    public func snapshot() -> WorkstreamStoreSnapshot {
        WorkstreamStoreSnapshot(
            items: items,
            pendingCount: pendingCount,
            actionableCount: actionableCount,
            hasMorePersistedItems: hasMorePersistedItems,
            isLoadingOlderItems: isLoadingOlderItems
        )
    }

    /// Emits the current projection and coalesced changes for the UI layer.
    public func snapshots() -> AsyncStream<WorkstreamStoreSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            snapshotContinuations[id] = continuation
            continuation.yield(snapshot())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSnapshotContinuation(id) }
            }
        }
    }

    private func removeSnapshotContinuation(_ id: UUID) {
        snapshotContinuations.removeValue(forKey: id)
    }

    private func publishSnapshot() {
        let current = snapshot()
        for continuation in snapshotContinuations.values {
            continuation.yield(current)
        }
    }

    /// Schedules one frame-coalesced snapshot publication for the UI.
    private func scheduleSnapshot() {
        guard snapshotTask == nil else { return }
        snapshotTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard !Task.isCancelled else { return }
            await self?.finishSnapshotTask()
        }
    }

    private func finishSnapshotTask() {
        snapshotTask = nil
        publishSnapshot()
    }

    public func loadOlderItems() async {
        guard !isLoadingOlderItems, hasMorePersistedItems else { return }
        guard let persistence, let oldestLoadedPersistenceOffset else {
            hasMorePersistedItems = false
            return
        }

        isLoadingOlderItems = true
        scheduleSnapshot()
        defer {
            isLoadingOlderItems = false
            scheduleSnapshot()
        }

        guard let page = try? await persistence.loadPage(
            endingBefore: oldestLoadedPersistenceOffset,
            limit: historyPageSize
        ), !page.items.isEmpty else {
            hasMorePersistedItems = false
            return
        }

        let existingIds = Set(items.map(\.id))
        let olderItems = page.items.map(normalizedWorkstreamItem).filter {
            !existingIds.contains($0.id)
        }
        if !olderItems.isEmpty {
            items.insert(contentsOf: olderItems, at: 0)
            for item in olderItems {
                addCounts(for: item)
            }
        }
        self.oldestLoadedPersistenceOffset = page.startOffset ?? oldestLoadedPersistenceOffset
        hasMorePersistedItems = page.hasMoreBefore
        rebuildContextIndex()
        scheduleSnapshot()
    }

    // MARK: - Ingest

    /// Applies an inbound wire frame. Creates or updates a
    /// `WorkstreamItem`, enforces the ring-buffer cap, and appends to
    /// the JSONL log.
    func ingestPrepared(_ item: WorkstreamItem) {
        insert(item)
        updateContextIndex(with: item)
        if let persistence {
            Task { [persistence, item] in
                try? await persistence.append(item)
            }
        }
        scheduleSnapshot()
    }

    // MARK: - Actions

    /// Sends a user-initiated action through the transport and marks the
    /// corresponding item resolved on success.
    public func send(_ action: WorkstreamAction) async throws {
        try await transport.send(action)
        applyResolution(for: action)
    }

    /// Marks the local item resolved without sending. Used when the reply
    /// channel is being driven by another layer (e.g. an inbound socket
    /// resolution event).
    public func markResolved(_ itemId: UUID, decision: WorkstreamDecision) {
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else { return }
        guard items[idx].status.isPending else { return }
        let now = clock()
        items[idx].status = .resolved(decision, at: now)
        items[idx].updatedAt = now
        pendingCount -= 1
        scheduleSnapshot()
    }

    public func markResolved(requestId: String, decision: WorkstreamDecision) {
        guard let item = items.reversed().first(where: { $0.payload.requestID == requestId }) else { return }
        markResolved(item.id, decision: decision)
    }

    /// Marks one still-pending item expired.
    public func markExpired(_ itemId: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else { return }
        guard items[idx].status.isPending else { return }
        let now = clock()
        items[idx].status = .expired(at: now)
        items[idx].updatedAt = now
        pendingCount -= 1
        scheduleSnapshot()
    }

    /// Marks every still-pending item created before `threshold` as
    /// expired. Call periodically to clean stale items.
    public func expirePending(olderThan threshold: TimeInterval) {
        let now = clock()
        for idx in items.indices {
            guard items[idx].status.isPending else { continue }
            if now.timeIntervalSince(items[idx].createdAt) > threshold {
                items[idx].status = .expired(at: now)
                items[idx].updatedAt = now
                pendingCount -= 1
            }
        }
        scheduleSnapshot()
    }

    // MARK: - Private helpers

    private func insert(_ item: WorkstreamItem) {
        items.append(item)
        addCounts(for: item)
        if items.count > ringCapacity {
            let overflow = items.count - ringCapacity
            let evicted = Array(items.prefix(overflow))
            items.removeFirst(overflow)
            for item in evicted {
                removeCounts(for: item)
            }
        }
    }

    private func addCounts(for item: WorkstreamItem) {
        if item.status.isPending { pendingCount += 1 }
        if item.kind.isActionable { actionableCount += 1 }
    }

    private func removeCounts(for item: WorkstreamItem) {
        if item.status.isPending { pendingCount -= 1 }
        if item.kind.isActionable { actionableCount -= 1 }
    }

    private func recomputeCounts() {
        pendingCount = items.reduce(into: 0) { count, item in
            if item.status.isPending { count += 1 }
        }
        actionableCount = items.reduce(into: 0) { count, item in
            if item.kind.isActionable { count += 1 }
        }
    }

    private func applyResolution(for action: WorkstreamAction) {
        switch action {
        case .approvePermission(let itemId, let mode):
            markResolved(itemId, decision: .permission(mode))
        case .replyQuestion(let itemId, let selections):
            markResolved(itemId, decision: .question(selections: selections))
        case .approveExitPlan(let itemId, let mode, let feedback):
            markResolved(itemId, decision: .exitPlan(mode, feedback: feedback))
        case .jumpToSession:
            // Jump is a navigation action; the item (if any) is unchanged.
            break
        }
    }

    func makeItem(from event: WorkstreamEvent) -> WorkstreamItem {
        let parsedSource = WorkstreamSource(wireName: event.source)
        let source = parsedSource ?? .claude
        let sourceID = parsedSource == nil ? event.source : nil
        let workstreamID = workstreamIDNormalizer(event.sessionId, event.source)
        let (kind, payload) = decode(event: event, source: source)
        let status: WorkstreamStatus = kind.isActionable ? .pending : .telemetry
        return WorkstreamItem(
            workstreamId: workstreamID,
            source: source,
            sourceID: sourceID,
            kind: kind,
            createdAt: event.receivedAt,
            updatedAt: event.receivedAt,
            cwd: event.cwd,
            title: defaultTitle(for: event),
            status: status,
            payload: payload,
            context: context(
                for: event,
                payload: payload,
                workstreamID: workstreamID
            ),
            ppid: event.ppid
        )
    }

    /// Marks every pending item with `ppid` as `.expired`. Meant to
    /// be called from a kqueue/DispatchSource process-exit handler
    /// so the exact moment an agent dies, its pending cards close.
    public func expireItems(forPpid ppid: Int) {
        let now = clock()
        for idx in items.indices {
            guard items[idx].status.isPending,
                  items[idx].ppid == ppid else { continue }
            items[idx].status = .expired(at: now)
            items[idx].updatedAt = now
            pendingCount -= 1
        }
        scheduleSnapshot()
    }

    /// Marks every pending item whose emitting agent process is no
    /// longer alive as `.expired`. Used once at app startup to
    /// catch items restored from the JSONL log whose original
    /// agent never made it to the kqueue-watcher install; steady-
    /// state abandonment is driven by `expireItems(forPpid:)` from
    /// the DispatchSource handler instead.
    public func expireAbandonedItems(
        isProcessAlive: (Int) -> Bool = WorkstreamCore.defaultIsProcessAlive
    ) {
        let now = clock()
        for idx in items.indices {
            guard items[idx].status.isPending else { continue }
            guard let ppid = items[idx].ppid, ppid > 0 else { continue }
            if !isProcessAlive(ppid) {
                items[idx].status = .expired(at: now)
                items[idx].updatedAt = now
                pendingCount -= 1
            }
        }
        scheduleSnapshot()
    }

    /// Default liveness probe: `kill(pid, 0)` returns 0 if the
    /// process exists and is signalable. `ESRCH` means gone;
    /// `EPERM` means alive but owned by another user (treat as
    /// alive — hook PIDs in practice are always same-user).
    public static let defaultIsProcessAlive: @Sendable (Int) -> Bool = { pid in
        #if canImport(Darwin) || canImport(Glibc)
        let rc = kill(pid_t(pid), 0)
        if rc == 0 { return true }
        return errno == EPERM
        #else
        return true
        #endif
    }

    private func decode(
        event: WorkstreamEvent,
        source: WorkstreamSource
    ) -> (WorkstreamKind, WorkstreamPayload) {
        let toolInput = event.toolInputJSON ?? "{}"
        switch event.hookEventName {
        case .permissionRequest:
            return (
                .permissionRequest,
                .permissionRequest(
                    requestId: event.requestId ?? event.sessionId,
                    toolName: event.toolName ?? "unknown",
                    toolInputJSON: toolInput,
                    pattern: nil
                )
            )
        case .askUserQuestion:
            let parsed = WorkstreamQuestionPrompt.parse(toolInputJSON: event.toolInputJSON)
            return (
                .question,
                .question(
                    requestId: event.requestId ?? event.sessionId,
                    questions: parsed
                )
            )
        case .exitPlanMode:
            return (
                .exitPlan,
                .exitPlan(
                    requestId: event.requestId ?? event.sessionId,
                    plan: toolInput,
                    defaultMode: .manual
                )
            )
        case .preToolUse:
            return (.toolUse, .toolUse(toolName: event.toolName ?? "", toolInputJSON: toolInput))
        case .postToolUse:
            return (
                .toolResult,
                .toolResult(toolName: event.toolName ?? "", resultJSON: toolInput, isError: event.isError ?? false)
            )
        case .postToolUseFailure:
            return (
                .toolResult,
                .toolResult(toolName: event.toolName ?? "", resultJSON: toolInput, isError: true)
            )
        case .preCompact:
            return (.toolUse, .toolUse(toolName: titleProvider(event) ?? event.hookEventName.rawValue, toolInputJSON: toolInput))
        case .postCompact:
            return (
                .toolResult,
                .toolResult(toolName: titleProvider(event) ?? event.hookEventName.rawValue, resultJSON: toolInput, isError: false)
            )
        case .subagentStart:
            return (.toolUse, .toolUse(toolName: titleProvider(event) ?? event.hookEventName.rawValue, toolInputJSON: toolInput))
        case .subagentStop:
            return (
                .toolResult,
                .toolResult(toolName: titleProvider(event) ?? event.hookEventName.rawValue, resultJSON: toolInput, isError: false)
            )
        case .userPromptSubmit:
            let prompt = Self.promptText(from: event.toolInputJSON)
            return (
                .userPrompt,
                .userPrompt(text: prompt.isEmpty ? (event.context?.lastUserMessage ?? "") : prompt)
            )
        case .sessionStart:
            return (.sessionStart, .sessionStart)
        case .sessionEnd:
            return (.sessionEnd, .sessionEnd)
        case .stop:
            return (.stop, .stop(reason: Self.stopReason(from: event.toolInputJSON)))
        case .todoWrite:
            return (.todos, .todos(Self.todos(from: event.toolInputJSON)))
        case .notification:
            return (.toolResult, .toolResult(toolName: "notification", resultJSON: toolInput, isError: false))
        }
    }

    private func defaultTitle(for event: WorkstreamEvent) -> String? {
        if let tool = event.toolName, !tool.isEmpty {
            return tool
        }
        return titleProvider(event)
    }

    private static func jsonObject(from json: String?) -> Any? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private static func promptText(from json: String?) -> String {
        if let dict = jsonObject(from: json) as? [String: Any] {
            return (dict["prompt"] as? String)
                ?? (dict["text"] as? String)
                ?? (dict["message"] as? String)
                ?? ""
        }
        return json ?? ""
    }

    private func rebuildContextIndex() {
        lastContextByWorkstream.removeAll(keepingCapacity: true)
        for item in items.sorted(by: { $0.createdAt < $1.createdAt }) {
            updateContextIndex(with: item)
        }
    }

    private func context(
        for event: WorkstreamEvent,
        payload: WorkstreamPayload,
        workstreamID: String
    ) -> WorkstreamContext? {
        let fallback = lastContextByWorkstream[workstreamID]
            ?? (workstreamID == event.sessionId
                ? nil
                : lastContextByWorkstream[event.sessionId])
        var context = event.context?.mergingMissing(from: fallback) ?? fallback

        switch payload {
        case .userPrompt(let text):
            context = WorkstreamContext(lastUserMessage: text).mergingMissing(from: context)
        case .assistantMessage(let text):
            context = WorkstreamContext(assistantPreamble: text).mergingMissing(from: context)
        case .exitPlan(_, let plan, _):
            let preview = WorkstreamExitPlanPreview(rawPlan: plan)
            context = WorkstreamContext(
                planSummary: preview.summary,
                allowedPrompts: preview.allowedPrompts
            )
            .mergingMissing(from: context)
        default:
            break
        }

        guard let context, !context.isEmpty else { return nil }
        return context
    }

    private func updateContextIndex(with item: WorkstreamItem) {
        let current = lastContextByWorkstream[item.workstreamId]
        var next: WorkstreamContext?

        if let context = item.context {
            next = Self.carriedContext(from: context)?.mergingMissing(from: current)
        }

        switch item.payload {
        case .userPrompt(let text):
            next = WorkstreamContext(lastUserMessage: text).mergingMissing(from: next ?? current)
        case .assistantMessage(let text):
            next = WorkstreamContext(assistantPreamble: text).mergingMissing(from: next ?? current)
        default:
            break
        }

        guard let next, !next.isEmpty else { return }
        lastContextByWorkstream[item.workstreamId] = next
    }

    private static func carriedContext(from context: WorkstreamContext) -> WorkstreamContext? {
        let carried = WorkstreamContext(
            lastUserMessage: context.lastUserMessage,
            assistantPreamble: context.assistantPreamble,
            permissionMode: context.permissionMode
        )
        return carried.isEmpty ? nil : carried
    }

    private static func stopReason(from json: String?) -> String? {
        if let dict = jsonObject(from: json) as? [String: Any] {
            return (dict["reason"] as? String)
                ?? (dict["message"] as? String)
                ?? (dict["cause"] as? String)
        }
        return nil
    }

    private static func todos(from json: String?) -> [WorkstreamTaskTodo] {
        let rawTodos: [Any]
        if let dict = jsonObject(from: json) as? [String: Any] {
            rawTodos = dict["todos"] as? [Any] ?? []
        } else {
            rawTodos = jsonObject(from: json) as? [Any] ?? []
        }
        return rawTodos.enumerated().compactMap { idx, raw in
            guard let dict = raw as? [String: Any] else { return nil }
            let content = (dict["content"] as? String)
                ?? (dict["text"] as? String)
                ?? (dict["title"] as? String)
                ?? ""
            guard !content.isEmpty else { return nil }
            let rawState = (dict["state"] as? String)
                ?? (dict["status"] as? String)
                ?? "pending"
            let state: WorkstreamTaskTodo.State
            switch rawState {
            case "completed", "done":
                state = .completed
            case "inProgress", "in_progress", "active":
                state = .inProgress
            default:
                state = .pending
            }
            return WorkstreamTaskTodo(
                id: (dict["id"] as? String) ?? "todo\(idx)",
                content: content,
                state: state
            )
        }
    }
}
