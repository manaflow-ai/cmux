import Foundation
import Observation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Size of the in-memory ring buffer. Older items are evicted to disk-only.
public let WorkstreamDefaultRingCapacity = 2_000
public let WorkstreamDefaultInitialLoadLimit = 300
public let WorkstreamDefaultHistoryPageSize = 300

/// Main-actor `@Observable` store that holds the Feed state.
///
/// One instance per cmux process. All windows observe it through the
/// SwiftUI environment; mutations happen on the main actor, which matches
/// the store's observation boundary and keeps SwiftUI view updates
/// deterministic.
///
@MainActor
@Observable
public final class WorkstreamStore {
    /// One page of immutable Feed history for mobile clients.
    public struct HistoryPage: Sendable, Equatable {
        /// Items in oldest-first order.
        public let items: [WorkstreamItem]
        /// Opaque cursor for the next older page.
        public let nextCursor: String?
        /// Whether persisted history exists before this page.
        public let hasMore: Bool

        /// Creates a mobile history page.
        public init(items: [WorkstreamItem], nextCursor: String?, hasMore: Bool) {
            self.items = items
            self.nextCursor = nextCursor
            self.hasMore = hasMore
        }
    }

    public private(set) var items: [WorkstreamItem] = []
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
    private let titleProvider: (WorkstreamEvent) -> String?
    private var oldestLoadedPersistenceOffset: UInt64?
    private var pendingPersistenceItems: [WorkstreamItem] = []
    private var persistenceDrainTask: Task<Void, Never>?

    var activePersistenceDrainCount: Int { persistenceDrainTask == nil ? 0 : 1 }

    /// Last known conversational context for each workstream. Tool hooks
    /// usually arrive without the surrounding user prompt, so the store
    /// carries forward prompt/preamble context from nearby telemetry rows.
    private var lastContextByWorkstream: [String: WorkstreamContext] = [:]

    /// Creates a store for Feed workstream items.
    ///
    /// - Parameters:
    ///   - transport: Source and reply transport for live Feed events.
    ///   - persistence: Optional JSONL persistence for event history.
    ///   - ringCapacity: Maximum in-memory item count.
    ///   - initialLoadLimit: Maximum persisted item count loaded at startup.
    ///   - historyPageSize: Page size for older persisted history.
    ///   - clock: Clock used for timestamps and expiry checks.
    ///   - titleProvider: App boundary hook for localized display titles.
    public init(
        transport: any WorkstreamTransport = NullWorkstreamTransport(),
        persistence: WorkstreamPersistence? = nil,
        ringCapacity: Int = WorkstreamDefaultRingCapacity,
        initialLoadLimit: Int = WorkstreamDefaultInitialLoadLimit,
        historyPageSize: Int = WorkstreamDefaultHistoryPageSize,
        clock: @escaping @Sendable () -> Date = { Date() },
        titleProvider: @escaping (WorkstreamEvent) -> String? = { _ in nil }
    ) {
        self.transport = transport
        self.persistence = persistence
        self.ringCapacity = ringCapacity
        self.initialLoadLimit = initialLoadLimit
        self.historyPageSize = historyPageSize
        self.clock = clock
        self.titleProvider = titleProvider
    }

    public func start() async {
        if let persistence {
            if let page = try? await persistence.loadPage(limit: min(initialLoadLimit, ringCapacity)) {
                items = expiringRestoredPendingItems(page.items)
                hasMorePersistedItems = page.hasMoreBefore
                oldestLoadedPersistenceOffset = page.startOffset
                rebuildContextIndex()
            }
        }
        do {
            try await transport.subscribe { [weak self] event in
                guard let self else { return }
                Task { @MainActor in
                    self.ingest(event)
                }
            }
        } catch {
            // Transport failures are non-fatal; the store stays usable for
            // locally-injected items and tests.
        }
    }

    public func loadOlderItems() async {
        guard !isLoadingOlderItems, hasMorePersistedItems else { return }
        guard let persistence, let oldestLoadedPersistenceOffset else {
            hasMorePersistedItems = false
            return
        }

        isLoadingOlderItems = true
        defer { isLoadingOlderItems = false }

        guard let page = try? await persistence.loadPage(
            endingBefore: oldestLoadedPersistenceOffset,
            limit: historyPageSize
        ), !page.items.isEmpty else {
            hasMorePersistedItems = false
            return
        }

        let existingIds = Set(items.map(\.id))
        let olderItems = expiringRestoredPendingItems(page.items)
            .filter { !existingIds.contains($0.id) }
        if !olderItems.isEmpty {
            items.insert(contentsOf: olderItems, at: 0)
        }
        self.oldestLoadedPersistenceOffset = page.startOffset ?? oldestLoadedPersistenceOffset
        hasMorePersistedItems = page.hasMoreBefore
        rebuildContextIndex()
    }

    /// Loads one immutable persisted-history page for authenticated mobile Feed.
    /// The item cursor is stable while newer JSONL rows are appended.
    public func historyPage(endingBefore cursor: String?, limit: Int) async throws -> HistoryPage {
        let boundedLimit = min(max(limit, 1), WorkstreamDefaultHistoryPageSize)
        guard let persistence else {
            let end: Int
            if let cursor {
                let decoded = try Self.decodeHistoryCursor(cursor, expectedVersion: "m1")
                guard decoded.position < UInt64(items.count),
                      items[Int(decoded.position)].id == decoded.itemID else {
                    throw WorkstreamHistoryError.invalidCursor
                }
                end = Int(decoded.position)
            } else {
                end = items.count
            }
            let start = max(0, end - boundedLimit)
            let pageItems = Array(items[start..<end])
            return HistoryPage(
                items: pageItems,
                nextCursor: start > 0 ? pageItems.first.map { Self.historyCursor(version: "m1", position: UInt64(start), itemID: $0.id) } : nil,
                hasMore: start > 0
            )
        }
        while let drain = persistenceDrainTask {
            await drain.value
        }
        let endOffset: UInt64?
        if let cursor {
            let decoded = try Self.decodeHistoryCursor(cursor, expectedVersion: "p1")
            guard try await persistence.itemID(startingAt: decoded.position) == decoded.itemID else {
                throw WorkstreamHistoryError.invalidCursor
            }
            endOffset = decoded.position
        } else {
            endOffset = nil
        }
        let page = try await persistence.loadPage(endingBefore: endOffset, limit: boundedLimit)
        let currentByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var pageItems = expiringRestoredPendingItems(page.items)
            .map { currentByID[$0.id] ?? $0 }
        var droppedPersistedItems = false
        if cursor == nil {
            let persistedIDs = Set(pageItems.map(\.id))
            let liveTailStart = page.items.last
                .flatMap { persisted in items.firstIndex(where: { $0.id == persisted.id }) }
                .map { items.index(after: $0) }
                ?? items.startIndex
            let liveCandidates = items[liveTailStart...].filter { !persistedIDs.contains($0.id) }
            let liveLimit = pageItems.isEmpty ? boundedLimit : max(0, boundedLimit - 1)
            let liveTail = liveCandidates.suffix(liveLimit)
            pageItems.append(contentsOf: liveTail)
            if pageItems.count > boundedLimit {
                let overflow = pageItems.count - boundedLimit
                droppedPersistedItems = overflow > 0 && !page.items.isEmpty
                pageItems.removeFirst(overflow)
            }
        }
        let firstPersisted = pageItems.first.flatMap { first in
            page.items.firstIndex(where: { $0.id == first.id }).flatMap { index in
                page.itemStartOffsets.indices.contains(index) ? page.itemStartOffsets[index] : nil
            }.map { (first, $0) }
        }
        let nextCursor = (page.hasMoreBefore || droppedPersistedItems)
            ? firstPersisted.map { item, offset in
                Self.historyCursor(version: "p1", position: offset, itemID: item.id)
            }
            : nil
        return HistoryPage(
            items: pageItems,
            nextCursor: nextCursor,
            hasMore: nextCursor != nil
        )
    }

    private static func historyCursor(version: String, position: UInt64, itemID: UUID) -> String {
        Data("\(version):\(position):\(itemID.uuidString)".utf8).base64EncodedString()
    }

    private static func decodeHistoryCursor(
        _ cursor: String,
        expectedVersion: String
    ) throws -> (position: UInt64, itemID: UUID) {
        guard let data = Data(base64Encoded: cursor),
              let raw = String(data: data, encoding: .utf8) else {
            throw WorkstreamHistoryError.invalidCursor
        }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == Substring(expectedVersion),
              let position = UInt64(parts[1]),
              let itemID = UUID(uuidString: String(parts[2])) else {
            throw WorkstreamHistoryError.invalidCursor
        }
        return (position, itemID)
    }

    // MARK: - Ingest

    /// Applies an inbound wire frame. Creates or updates a
    /// `WorkstreamItem`, enforces the ring-buffer cap, and appends to
    /// the JSONL log.
    public func ingest(_ event: WorkstreamEvent) {
        let item = makeItem(from: event)
        insert(item)
        updateContextIndex(with: item)
        if let persistence {
            pendingPersistenceItems.append(item)
            startPersistenceDrainIfNeeded(persistence: persistence)
        }
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
        items[idx].status = .resolved(
            Self.decisionForHistory(decision, payload: items[idx].payload),
            at: now
        )
        items[idx].updatedAt = now
    }

    /// Marks one still-pending item expired.
    public func markExpired(_ itemId: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else { return }
        guard items[idx].status.isPending else { return }
        let now = clock()
        items[idx].status = .expired(at: now)
        items[idx].updatedAt = now
    }

    /// Appends a user reply after a completed turn. The synthetic user-prompt
    /// row is authoritative for mobile Feed filtering: once it exists, the
    /// preceding stop/session-end row is historical and cannot be submitted
    /// again. The exact item identity and route are validated by the caller.
    public func canAppendUserReply(to itemId: UUID, text: String) -> Bool {
        guard let sourceIndex = items.firstIndex(where: { $0.id == itemId }),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return isTurnCompletion(items[sourceIndex])
            && items.lastIndex(where: { $0.workstreamId == items[sourceIndex].workstreamId }) == sourceIndex
    }

    @discardableResult
    public func appendUserReply(to itemId: UUID, text: String) -> Bool {
        guard canAppendUserReply(to: itemId, text: text),
              let sourceIndex = items.firstIndex(where: { $0.id == itemId }) else { return false }
        let source = items[sourceIndex]
        let now = clock()
        let reply = WorkstreamItem(
            workstreamId: source.workstreamId,
            source: source.source,
            sourceRawValue: source.sourceRawValue,
            kind: .userPrompt,
            createdAt: now,
            updatedAt: now,
            cwd: source.cwd,
            title: source.title,
            workspaceId: source.workspaceId,
            surfaceId: source.surfaceId,
            status: .telemetry,
            payload: .userPrompt(text: text),
            context: source.context,
            ppid: source.ppid
        )
        insert(reply)
        updateContextIndex(with: reply)
        if let persistence {
            pendingPersistenceItems.append(reply)
            startPersistenceDrainIfNeeded(persistence: persistence)
        }
        return true
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
            }
        }
    }

    // MARK: - Private helpers

    private func insert(_ item: WorkstreamItem) {
        items.append(item)
        if items.count > ringCapacity {
            let overflow = items.count - ringCapacity
            items.removeFirst(overflow)
        }
    }

    private func expiringRestoredPendingItems(_ restoredItems: [WorkstreamItem]) -> [WorkstreamItem] {
        let now = clock()
        return restoredItems.map { restoredItem in
            guard restoredItem.status.isPending else { return restoredItem }
            var expiredItem = restoredItem
            expiredItem.status = .expired(at: now)
            expiredItem.updatedAt = now
            return expiredItem
        }
    }

    private func startPersistenceDrainIfNeeded(persistence: WorkstreamPersistence) {
        guard persistenceDrainTask == nil else { return }
        persistenceDrainTask = Task { @MainActor [weak self, persistence] in
            guard let self else { return }
            while !Task.isCancelled, !self.pendingPersistenceItems.isEmpty {
                let batch = self.pendingPersistenceItems
                self.pendingPersistenceItems.removeAll(keepingCapacity: true)
                for item in batch {
                    try? await persistence.append(item)
                }
            }
            self.persistenceDrainTask = nil
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

    private func makeItem(from event: WorkstreamEvent) -> WorkstreamItem {
        let source = WorkstreamSource(wireName: event.source) ?? .claude
        let (kind, payload) = decode(event: event, source: source)
        let status: WorkstreamStatus = kind.isActionable ? .pending : .telemetry
        return WorkstreamItem(
            workstreamId: event.sessionId,
            source: source,
            sourceRawValue: event.source,
            kind: kind,
            createdAt: event.receivedAt,
            updatedAt: event.receivedAt,
            cwd: event.cwd,
            title: defaultTitle(for: event),
            workspaceId: event.workspaceId,
            surfaceId: event.surfaceId,
            status: status,
            payload: payload,
            context: context(for: event, payload: payload),
            ppid: event.ppid
        )
    }

    private func isTurnCompletion(_ item: WorkstreamItem) -> Bool {
        switch item.payload {
        case .stop, .sessionEnd:
            return true
        default:
            return false
        }
    }

    /// Feed keeps resolved choices visible, but secret elicitation values must
    /// never enter history or the phone cache. The blocking waiter retains the
    /// original decision independently, so the originating agent still gets
    /// the exact submitted value.
    private static func decisionForHistory(
        _ decision: WorkstreamDecision,
        payload: WorkstreamPayload
    ) -> WorkstreamDecision {
        let selections: [String]
        let formAction: WorkstreamFormAction?
        switch decision {
        case .question(let values):
            selections = values
            formAction = nil
        case .form(let action, let values):
            selections = values
            formAction = action
        default:
            return decision
        }
        guard case .question(_, let questions) = payload else {
            return decision
        }
        let secretIDs = Set(
            questions.lazy
                .filter { $0.inputType == .secret }
                .map(\.id)
        )
        guard !secretIDs.isEmpty else { return decision }
        let safeSelections = selections.map { selection in
            guard let separator = selection.firstIndex(of: "=") else {
                // Legacy desktop and notification clients may submit one
                // unkeyed value per prompt. Once a secret field is present,
                // do not persist an ambiguous value that could be its answer.
                return "<provided>"
            }
            let fieldID = String(selection[..<separator])
            guard secretIDs.contains(fieldID) else { return selection }
            return "\(fieldID)=<provided>"
        }
        if let formAction {
            return .form(action: formAction, selections: safeSelections)
        }
        return .question(selections: safeSelections)
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
        }
    }

    /// Marks every pending item whose emitting agent process is no
    /// longer alive as `.expired`. Used once at app startup to
    /// catch items restored from the JSONL log whose original
    /// agent never made it to the kqueue-watcher install; steady-
    /// state abandonment is driven by `expireItems(forPpid:)` from
    /// the DispatchSource handler instead.
    public func expireAbandonedItems(
        isProcessAlive: (Int) -> Bool = WorkstreamStore.defaultIsProcessAlive
    ) {
        let now = clock()
        for idx in items.indices {
            guard items[idx].status.isPending else { continue }
            guard let ppid = items[idx].ppid, ppid > 0 else { continue }
            if !isProcessAlive(ppid) {
                items[idx].status = .expired(at: now)
                items[idx].updatedAt = now
            }
        }
    }

    /// Default liveness probe: `kill(pid, 0)` returns 0 if the
    /// process exists and is signalable. `ESRCH` means gone;
    /// `EPERM` means alive but owned by another user (treat as
    /// alive — hook PIDs in practice are always same-user).
    public static let defaultIsProcessAlive: (Int) -> Bool = { pid in
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
        if let rawEvent = event.rawHookEventName,
           Self.isQuestionEvent(rawEvent) {
            let parsed = WorkstreamQuestionPrompt.parse(toolInputJSON: event.toolInputJSON)
            return (
                .question,
                .question(
                    requestId: event.requestId ?? event.sessionId,
                    questions: parsed
                )
            )
        }
        if let rawEvent = event.rawHookEventName,
           let telemetry = Self.unknownTelemetry(rawEvent, event: event, toolInput: toolInput) {
            return telemetry
        }
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
            return (
                .toolResult,
                .toolResult(
                    toolName: event.rawHookEventName ?? "notification",
                    resultJSON: toolInput,
                    isError: event.isError ?? false
                )
            )
        }
    }

    private static func isQuestionEvent(_ rawEvent: String) -> Bool {
        let normalized = rawEvent.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .lowercased()
        return [
            "askuserquestion",
            "askuserconfirmation",
            "booleanquestion",
            "questionasked",
            "questionv2asked",
            "elicitation",
            "elicitationrequest",
            "mcpelicitation",
            "mcpserverelicitationrequest",
            "requestuserinput",
            "userinputrequest",
            "inputrequest",
            "toolrequestuserinput",
            "itemtoolrequestuserinput",
            "question",
            "askuser",
        ].contains(normalized)
    }

    private static func unknownTelemetry(
        _ rawEvent: String,
        event: WorkstreamEvent,
        toolInput: String
    ) -> (WorkstreamKind, WorkstreamPayload)? {
        let normalized = rawEvent
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "/", with: "")
            .lowercased()
        let toolName = event.toolName ?? rawEvent
        if normalized.contains("failure") || normalized.contains("error") {
            return (
                .toolResult,
                .toolResult(toolName: toolName, resultJSON: toolInput, isError: true)
            )
        }
        if normalized.contains("completed") || normalized.contains("result") || normalized.contains("stop") || normalized.contains("idle") {
            return (
                .toolResult,
                .toolResult(toolName: toolName, resultJSON: toolInput, isError: event.isError ?? false)
            )
        }
        if normalized.contains("reasoning") || normalized.contains("message") {
            return (
                .assistantMessage,
                .assistantMessage(text: Self.promptText(from: event.toolInputJSON))
            )
        }
        if normalized.contains("task") || normalized.contains("plan") || normalized.contains("started") || normalized.contains("command") || normalized.contains("filechange") {
            return (
                .toolUse,
                .toolUse(toolName: toolName, toolInputJSON: toolInput)
            )
        }
        return (
            .toolResult,
            .toolResult(toolName: toolName, resultJSON: toolInput, isError: event.isError ?? false)
        )
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

    private func context(for event: WorkstreamEvent, payload: WorkstreamPayload) -> WorkstreamContext? {
        let fallback = lastContextByWorkstream[event.sessionId]
        var context = event.context?.mergingMissing(from: fallback) ?? fallback

        switch payload {
        case .userPrompt(let text):
            context = WorkstreamContext(lastUserMessage: text).mergingMissing(from: context)
        case .assistantMessage(let text):
            context = WorkstreamContext(assistantPreamble: text).mergingMissing(from: context)
        case .stop, .sessionEnd:
            // Stop hooks commonly carry the final assistant turn as a
            // top-level `last_assistant_message` field rather than inside
            // `tool_input`. Preserve it in the same carried context used by
            // the desktop Feed so mobile can render a useful completed-turn
            // card even when the reply route is stale or offline.
            // Some adapters put the answer in the explicit event context
            // instead. A fallback context from an earlier assistant preamble
            // is deliberately not treated as a final answer, otherwise a
            // stopped turn with no response would display an old preamble.
            if let finalMessage = Self.assistantMessage(from: event)
                ?? event.context?.assistantPreamble {
                context = WorkstreamContext(assistantPreamble: finalMessage)
                    .mergingMissing(from: context)
            } else {
                context = context.flatMap { Self.removingAssistantMessage(from: $0) }
            }
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

    /// Extracts the final assistant text emitted by stop/session adapters.
    /// Providers disagree on whether this is in `tool_input`, a nested
    /// notification/data object, or an extra top-level field, so keep the
    /// accepted key set deliberately small and fail closed for other values.
    private static func assistantMessage(from event: WorkstreamEvent) -> String? {
        let keys = [
            "last_assistant_message",
            "lastAssistantMessage",
            "assistant_message",
            "assistantMessage",
            "assistantPreamble",
            "assistant_preamble",
            "assistant_response",
            "assistantResponse",
            "last_response",
            "lastResponse",
            "final_message",
            "finalMessage",
            "final_response",
            "finalResponse",
            "last_agent_message",
            "lastAgentMessage",
        ]
        for json in [event.extraFieldsJSON, event.toolInputJSON] {
            guard let json,
                  let data = json.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(
                      with: data,
                      options: [.fragmentsAllowed]
                  ) else { continue }
            if let text = assistantMessage(from: value, keys: keys) {
                return text
            }
        }
        return nil
    }

    private static func assistantMessage(from value: Any, keys: [String]) -> String? {
        guard let dictionary = value as? [String: Any] else { return nil }
        for key in keys {
            if let text = dictionary[key] as? String,
               let normalized = normalizedMessage(text) {
                return normalized
            }
        }
        for key in ["notification", "data", "context", "message", "extra", "payload", "response"] {
            if let nested = dictionary[key] as? [String: Any],
               let text = assistantMessage(from: nested, keys: keys) {
                return text
            }
        }
        return nil
    }

    private static func removingAssistantMessage(from context: WorkstreamContext) -> WorkstreamContext? {
        let stripped = WorkstreamContext(
            lastUserMessage: context.lastUserMessage,
            planSummary: context.planSummary,
            allowedPrompts: context.allowedPrompts,
            toolSummary: context.toolSummary,
            permissionMode: context.permissionMode
        )
        return stripped.isEmpty ? nil : stripped
    }

    private static func normalizedMessage(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
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

/// Failure to resolve an immutable Feed history page.
public enum WorkstreamHistoryError: Error, Sendable, Equatable {
    /// The cursor is malformed, stale, or does not identify its claimed row.
    case invalidCursor
}
