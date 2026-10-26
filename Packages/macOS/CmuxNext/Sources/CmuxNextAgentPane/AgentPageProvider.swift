public import CmuxNextPages
public import CmuxNextSettings
public import Foundation

public extension PageDescriptor {
    /// The agent pane, and with it the new tab page (react-pages.md, agent pane move). It reaches
    /// only its own `cmux.agent.*` ops; the app actions it may run are checked by
    /// ``AgentPaneModel`` (`cmux.agent.action.run`), so it lists no shared native op.
    /// It opens no connection of its own (the host's native transport, AgentPaneTransport, carries
    /// acpmux; the Debug dev loop loads a Vite page in the legacy host, which sends no header), shows
    /// loopback previews and render cards (AgentPaneRenderFrame) in frames, and runs only its own script files, no inline script
    /// (plus WebAssembly compilation, `'wasm-unsafe-eval'`, for Ondine's Mermaid diagrams). The page's
    /// meta CSP says the same (build-agent-pane-web.sh; AgentPageCSPAlignmentTests); the host runs the
    /// user's registry.js through evaluateJavaScript, which the CSP does not govern.
    static let agent = PageDescriptor(
        id: "cmux.agent", resource: "agent-pane", namespaces: [AgentPageOps.namespace],
        csp: PageCSP(connect: ["'none'"],
                     frame: [AgentPaneRenderFrame.source, "http://localhost:*", "http://127.0.0.1:*", "https://localhost:*", "https://127.0.0.1:*"],
                     script: ["'wasm-unsafe-eval'"], inlineScript: false),
        // Permission cards (Allow once, Allow for chat), tool cards, Push, Apply and Remove act on one click and
        // appear when the agent decides: a click meant only to bring the window forward must not answer them.
        acceptsFirstMouse: false)
}

/// The `cmux.agent.*` ops: one per method of the old `agentSession` bridge, with the same params.
/// The op name is the method name, except the two renamed for the namespace.
public nonisolated struct AgentPageOps {
    public nonisolated init() {}
    public static let namespace = "cmux.agent."

    /// Op suffix to the old bridge method that ``AgentPaneRequest`` parses.
    static let methods: [String: String] = {
        var methods = Dictionary(uniqueKeysWithValues: [
            "pane.checkpointAvailability", "pane.framePacing", "pane.painted", "pane.renderRate", "pane.saveLog", "pane.saveFile", "pane.showContextUsage", "pane.showDictation", "pane.setDisplay", "pane.setAttachmentView",
            "pane.edit", "pane.setQuickActions", "tab.open", "run.attach", "tab.typeAhead", "tab.jump",
            "newTab.remember", "newTab.setTemplate", "newTab.editWidgets", "nowPlaying.command", "newTab.inputReady", "newTab.touched", "newTab.context", "newTab.warm", "shortcut.edit", "action.run", "file.open", "browser.open",
            "project.list", "project.icon", "project.browse", "workspace.chooseFolder", "workspace.useFolder", "chat.folder.choose", "chat.attach.choose", "chat.attach.dropped", "app.action", "chats.open", "chats.openInTerminal", "chats.watch", "chats.page",
            "quick.dismiss", "quick.openInWindow", "quick.startInBackground", "quick.setOnTop", "quick.setCollapsed", "quick.floatingState", "quick.context", "pane.action", "pane.tabState", "pane.tabRowTools", "chat.toolCard.respond", "chat.upload", "chat.sideChat", "chat.subagentPane", "chat.processTerminal", "chat.openTab", "chat.offer.open", "chat.asks.open", "chat.newHere", "chat.unsentDraft", "chat.scrollAnchor", "chat.scrollAnchor.get", "chat.tail", "chat.tail.get", "chat.draftAttachments", "chat.draftAttachments.get", "chat.asks.pending",
            "shell.run", "shell.read", "shell.stop", "harness.update", "harness.restart",
            "git.diff", "git.status", "git.commit", "git.push", "git.worktree.create", "git.worktree.apply", "git.worktree.remove", "git.githubRepository", "file.search", "git.checkpoint.diff", "turn.undo", "git.stage", "git.unstage", "git.stageHunk", "git.unstageHunk", "git.pullRequest", "project.instructions", "project.addFiles", "composer.capture",
            "dictation.toggle", "dictation.start", "dictation.stop", "dictation.cancel", "dictation.openSettings", "dictation.audio",
            "transport.open", "transport.send", "transport.close", "transport.gesture", "transport.gesture.release",
            "chat.missing", "uiPointer.report", "acpmux.restart",
        ].map { ($0, $0) })
        for method in AgentPaneReplyRequest.methods.union(AgentPaneEnvironmentRequest.methods) { methods[method] = method }
        methods["handshake"] = "ready"
        methods["session.persist"] = "chat.persistSession"
        return methods
    }()

    /// Every op the agent page may call.
    public static let all: [String] = methods.keys.sorted().map { namespace + $0 }

    /// The old bridge method for `op`, or nil for an op the page does not have.
    static func method(for op: String) -> String? {
        guard op.hasPrefix(namespace) else { return nil }
        return methods[String(op.dropFirst(namespace.count))]
    }
}

/// Serves the agent page's calls with the pane's ``AgentPaneModel``, as the old `agentSession`
/// handler did. `prepare` returns the model for a request (and does the view work a handshake
/// needs, such as pushing the theme again); nil means the pane is closed.
@MainActor
public final class AgentPageProvider: PageProvider {
    public typealias Prepare = @MainActor (AgentPaneRequest) -> AgentPaneModel?
    public static let maximumBufferedEvents = 8_192
    private static let replayBatchSize = 128

    /// The stream of host pushes (``AgentPageEvent``) the page subscribes to once its
    /// `cmuxAcpmuxBridge` is installed.
    public static let hostEvents = "cmux.agent.host.events"

    private let prepare: Prepare
    private var listeners: [UInt64: @MainActor (JSONValue) -> Void] = [:]
    private var bufferedEvents: [AgentPageEvent] = []
    private var transportConnection: Int?
    private var deliveryOverflowed = false
    private var nextDeliveryID: UInt64 = 1
    private var activeDeliveryID: UInt64?
    private var droppedPublicationIDs: Set<UInt64> = []
    private var deliveredPublicationIDs: Set<UInt64> = []
    private var pendingPublicationCounts: [UInt64: Int] = [:]
    private var bufferedQueueOverflowed = false
    private var overflowedPendingListeners: Set<UInt64> = []
    private final class PendingEvents {
        var events: [AgentPageEvent]
        var next = 0
        var requeued = false

        init(_ events: [AgentPageEvent]) {
            self.events = events
        }

        func requeueRemaining() -> [AgentPageEvent] {
            guard !requeued else { return [] }
            requeued = true
            let remaining = Array(events[next...])
            next = events.count
            return remaining
        }

        func compactDelivered() {
            guard next >= 128, next * 2 >= events.count else { return }
            events.removeFirst(next)
            next = 0
        }
    }
    private var pendingEvents: [UInt64: PendingEvents] = [:]
    private var nextListener: UInt64 = 1
    /// The current state a new subscriber gets first (theme, shortcuts, preview, customization),
    /// as the old host pushed it again on every handshake.
    public var replay: (@MainActor () -> [AgentPageEvent])?
    /// Runs a composer menu edit (`pane.edit`) in the page view; ``AgentPanePageHost`` sets it.
    public var onEdit: (@MainActor (AgentPaneEditCommand) -> Void)?
    /// The pane's own acpmux socket (``AgentPaneModel/pendingAsksSocket``), asked at each
    /// `chat.asks.pending`: its chats are read there and nowhere else. ``AgentPaneView`` sets it;
    /// until then, and whenever it is nil, the op answers null.
    public var pendingAsksSocket: @MainActor () -> String? = { nil }
    /// Reads `chat.asks.pending` through ``pendingAsksSocket`` (tests inject the reader).
    public var pendingAsks = AgentPanePendingAsks()
    /// The debug UI pointer report from an app-owned page. The native picker
    /// owns the crop and composer delivery; the page only supplies metadata.
    public var onUiPointerReport: @MainActor (JSONValue) -> Void = { _ in }

    public init(prepare: @escaping Prepare) {
        self.prepare = prepare
    }

    public var eventDeliveryID: UInt64? { activeDeliveryID }

    public func transportDidOpen(_ connection: Int) {
        guard transportConnection != connection else { return }
        transportConnection = connection
        droppedPublicationIDs.removeAll(keepingCapacity: true)
        if bufferedQueueOverflowed { bufferedEvents.removeAll(keepingCapacity: true) }
        bufferedQueueOverflowed = false
        for id in overflowedPendingListeners {
            pendingEvents.removeValue(forKey: id)
            guard let listener = listeners[id] else { continue }
            for event in replay?() ?? [] { listener(event.data) }
        }
        overflowedPendingListeners.removeAll(keepingCapacity: true)
        let pendingIDs = Set(pendingEvents.values.flatMap { pending in
            pending.events.dropFirst(pending.next).compactMap(\.deliveryID)
        })
        deliveredPublicationIDs = deliveredPublicationIDs.intersection(pendingIDs)
        pendingPublicationCounts.removeAll(keepingCapacity: true)
        for pending in pendingEvents.values {
            for event in pending.events.dropFirst(pending.next) { addPending(event) }
        }
        deliveryOverflowed = false
    }

    public var eventsAfterSubscribeReply: Bool { true }

    public func eventDeliveryDropped(stream: String, data: JSONValue, publicationID: UInt64? = nil) {
        guard stream == Self.hostEvents,
              case .string(let kind)? = data["kind"],
              let publicationID else { return }
        guard droppedPublicationIDs.insert(publicationID).inserted else { return }
        if droppedPublicationIDs.count > Self.maximumBufferedEvents {
            droppedPublicationIDs.removeAll(keepingCapacity: true)
        }
        deliveredPublicationIDs.remove(publicationID)
        let value = data["value"] ?? .null
        appendRequeued([AgentPageEvent(kind: kind, value: value, deliveryID: publicationID)])
    }

    /// Sends `event` to every subscribed page.
    @discardableResult
    public func publish(_ event: AgentPageEvent) -> Bool {
        let publicationID = event.deliveryID ?? nextDeliveryID
        if event.deliveryID == nil { nextDeliveryID &+= 1 }
        let event = event.deliveryID == nil
            ? AgentPageEvent(kind: event.kind, value: event.value, deliveryID: publicationID)
            : event
        if deliveryOverflowed, event.kind == "transport", event.value["closed"] != nil {
            for id in listeners.keys.sorted() { listeners[id]?(event.data) }
            return true
        }
        guard !deliveryOverflowed else { return false }
        guard !listeners.isEmpty else {
            guard bufferedEvents.count < Self.maximumBufferedEvents else {
                bufferedQueueOverflowed = true
                deliveryOverflowed = true
                return false
            }
            bufferedEvents.append(event)
            return true
        }
        var accepted = true
        let hasPendingListener = listeners.keys.contains { pendingEvents[$0] != nil }
        for id in listeners.keys.sorted() {
            let previousDeliveryID = activeDeliveryID
            activeDeliveryID = event.deliveryID
            if let pending = pendingEvents[id] {
                guard pending.events.count - pending.next < Self.maximumBufferedEvents else {
                    deliveryOverflowed = true
                    overflowedPendingListeners.insert(id)
                    accepted = false
                    activeDeliveryID = previousDeliveryID
                    continue
                }
                pending.events.append(event)
                addPending(event)
            } else {
                if let deliveryID = event.deliveryID, hasPendingListener {
                    deliveredPublicationIDs.insert(deliveryID)
                }
                listeners[id]?(event.data)
            }
            activeDeliveryID = previousDeliveryID
        }
        return accepted
    }

    public var hasSubscribers: Bool { !listeners.isEmpty }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.hostEvents else { throw PageError.unknownOp(stream) }
        if listeners.isEmpty { droppedPublicationIDs.removeAll(keepingCapacity: true) }
        if listeners.isEmpty { deliveredPublicationIDs.removeAll(keepingCapacity: true) }
        if listeners.isEmpty { pendingPublicationCounts.removeAll(keepingCapacity: true) }
        if deliveryOverflowed, listeners.isEmpty {
            bufferedEvents.removeAll(keepingCapacity: true)
            deliveryOverflowed = false
            bufferedQueueOverflowed = false
        }
        let id = nextListener
        nextListener += 1
        listeners[id] = onEvent
        let buffered = bufferedEvents
        bufferedEvents.removeAll()
        let pending = PendingEvents(buffered)
        for event in buffered { addPending(event) }
        pendingEvents[id] = pending
        let replayEvents = self.replay?() ?? []
        pending.events.insert(contentsOf: replayEvents, at: pending.next)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.flushPendingEvents(for: id)
        }
        return PageSubscription { [weak self] in self?.cancel(id: id) }
    }

    private func flushPendingEvents(for id: UInt64) {
        guard let pending = pendingEvents[id] else { return }
        guard listeners[id] != nil else {
            requeuePendingEvents(for: id, pending: pending)
            return
        }
        let end = min(pending.events.count, pending.next + Self.replayBatchSize)
        while pending.next < end {
            guard let listener = listeners[id] else {
                requeuePendingEvents(for: id, pending: pending)
                return
            }
            let event = pending.events[pending.next]
            pending.next += 1
            consumePending(event)
            if let deliveryID = event.deliveryID { bufferedEvents.removeAll { $0.deliveryID == deliveryID } }
            let previousDeliveryID = activeDeliveryID
            activeDeliveryID = event.deliveryID
            if let deliveryID = event.deliveryID, pendingPublicationCounts[deliveryID] != nil {
                deliveredPublicationIDs.insert(deliveryID)
            }
            listener(event.data)
            activeDeliveryID = previousDeliveryID
        }
        pending.compactDelivered()
        if pending.next < pending.events.count {
            Task { @MainActor [weak self] in self?.flushPendingEvents(for: id) }
            return
        }
        pendingEvents.removeValue(forKey: id)
    }

    private func cancel(id: UInt64) {
        listeners.removeValue(forKey: id)
        overflowedPendingListeners.remove(id)
        if let pending = pendingEvents.removeValue(forKey: id) {
            let remaining = pending.requeueRemaining()
            removePending(remaining, preservingDelivered: true)
            appendRequeued(remaining)
        }
    }

    private func requeuePendingEvents(for id: UInt64, pending: PendingEvents) {
        pendingEvents.removeValue(forKey: id)
        listeners.removeValue(forKey: id)
        overflowedPendingListeners.remove(id)
        let remaining = pending.requeueRemaining()
        removePending(remaining, preservingDelivered: true)
        appendRequeued(remaining)
    }

    private func appendRequeued(_ events: [AgentPageEvent]) {
        guard !events.isEmpty else { return }
        var byID: [UInt64: AgentPageEvent] = [:]
        for event in bufferedEvents {
            if let deliveryID = event.deliveryID { byID[deliveryID] = event }
        }
        let uniqueEvents = events.filter { event in
            guard let deliveryID = event.deliveryID else { return false }
            guard byID[deliveryID] == nil, !deliveredPublicationIDs.contains(deliveryID) else { return false }
            byID[deliveryID] = event
            return true
        }
        let merged = byID.values.sorted { ($0.deliveryID ?? 0) < ($1.deliveryID ?? 0) }
        guard merged.count <= Self.maximumBufferedEvents else {
            bufferedQueueOverflowed = true
            deliveryOverflowed = true
            return
        }
        deliveredPublicationIDs = deliveredPublicationIDs.filter { pendingPublicationCounts[$0] != nil }
        guard !uniqueEvents.isEmpty else { return }
        bufferedEvents = merged
    }

    private func addPending(_ event: AgentPageEvent) {
        guard let deliveryID = event.deliveryID else { return }
        pendingPublicationCounts[deliveryID, default: 0] += 1
    }

    private func consumePending(_ event: AgentPageEvent) {
        guard let deliveryID = event.deliveryID, let count = pendingPublicationCounts[deliveryID] else { return }
        if count == 1 {
            pendingPublicationCounts.removeValue(forKey: deliveryID)
            deliveredPublicationIDs.remove(deliveryID)
        } else {
            pendingPublicationCounts[deliveryID] = count - 1
        }
    }

    private func removePending(_ events: [AgentPageEvent], preservingDelivered: Bool) {
        for event in events {
            guard let deliveryID = event.deliveryID, let count = pendingPublicationCounts[deliveryID] else { continue }
            if count == 1 {
                pendingPublicationCounts.removeValue(forKey: deliveryID)
                if !preservingDelivered { deliveredPublicationIDs.remove(deliveryID) }
            } else {
                pendingPublicationCounts[deliveryID] = count - 1
            }
        }
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard let method = AgentPageOps.method(for: op) else { throw PageError.unknownOp(op) }
        if method == "pane.edit" { return try edit(params, op: op, context: context) }
        // Named, not a prefix: `scrollAnchor` treats anything but `.get` as a write, so a later
        // `chat.scrollAnchor.forget` would have erased a chat's place instead of being refused.
        if AgentPaneScrollAnchors.handles(method: method) { return try Self.scrollAnchor(method, params: params, op: op) }
        if AgentPaneTailCache.handles(method: method) { return try Self.tail(method, params: params, op: op) }
        // Needs you's read of a chat's open requests: the host's, never the relay's (AgentPanePendingAsks).
        if method == "chat.asks.pending" { return try await pendingAsks.reply(params, op: op, socket: pendingAsksSocket()) }
        if method == "uiPointer.report" {
            onUiPointerReport(params)
            return .object(["ok": .bool(true)])
        }
        if method.hasPrefix("chat.draftAttachments") { return try await Self.draftAttachments(method, params: params, op: op) }
        let request = AgentPaneRequest(body: ["method": method, "params": params.foundationObject])
        if case .unsupported = request { throw PageError.invalidParams(op) }
        guard let model = prepare(request) else { throw PageError.closed }
        return try Self.value(of: await model.respond(to: request))
    }

    /// The value of an ``AgentPaneReply``, or its failure as a ``PageError``. The model's code and
    /// message are kept; its `origin` and `details` travel in the error's details.
    public nonisolated static func value(of reply: [String: Any]) throws -> JSONValue {
        if reply["ok"] as? Bool == true {
            guard let value = reply["value"] else { return .null }
            guard let json = JSONValue(foundation: value) else {
                throw PageError(code: "native.failed", message: "The agent pane reply is not JSON")
            }
            return json
        }
        let error = reply["error"] as? [String: Any] ?? [:]
        var details: [String: JSONValue] = [:]
        if let origin = error["origin"] as? String { details["origin"] = .string(origin) }
        if let inner = error["details"].flatMap(JSONValue.init(foundation:)) { details["details"] = inner }
        throw PageError(code: error["code"] as? String ?? "native.failed",
                        message: error["userMessage"] as? String ?? "",
                        retryable: error["retryable"] as? Bool ?? false,
                        details: details.isEmpty ? nil : .object(details))
    }
}
