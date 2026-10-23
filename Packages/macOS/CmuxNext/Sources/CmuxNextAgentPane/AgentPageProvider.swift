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
            "pane.checkpointAvailability", "pane.framePacing", "pane.painted", "pane.renderRate", "pane.saveLog", "pane.saveFile", "pane.showContextUsage", "pane.showDictation", "pane.setDisplay",
            "pane.edit", "pane.setQuickActions", "tab.open", "run.attach", "tab.typeAhead", "tab.jump",
            "newTab.remember", "newTab.setTemplate", "newTab.editWidgets", "nowPlaying.command", "newTab.inputReady", "newTab.touched", "newTab.context", "newTab.warm", "shortcut.edit", "action.run", "file.open", "browser.open",
            "project.list", "project.icon", "project.browse", "workspace.chooseFolder", "workspace.useFolder", "chat.folder.choose", "chat.attach.choose", "chat.attach.dropped", "app.action", "chats.open", "chats.openInTerminal", "chats.watch", "chats.page",
            "quick.dismiss", "quick.openInWindow", "quick.startInBackground", "quick.setOnTop", "quick.setCollapsed", "quick.floatingState", "quick.context", "pane.action", "pane.tabState", "pane.tabRowTools", "chat.toolCard.respond", "chat.upload", "chat.sideChat", "chat.subagentPane", "chat.processTerminal", "chat.openTab", "chat.offer.open", "chat.asks.open", "chat.newHere", "chat.unsentDraft", "chat.scrollAnchor", "chat.scrollAnchor.get", "chat.tail", "chat.tail.get", "chat.draftAttachments", "chat.draftAttachments.get", "chat.asks.pending",
            "shell.run", "shell.read", "shell.stop", "harness.update", "harness.restart",
            "git.diff", "git.status", "git.commit", "git.push", "git.worktree.create", "git.worktree.apply", "git.worktree.remove", "git.githubRepository", "file.search", "git.checkpoint.diff", "turn.undo", "git.stage", "git.unstage", "git.stageHunk", "git.unstageHunk", "git.pullRequest", "project.instructions", "project.addFiles", "composer.capture",
            "dictation.toggle", "dictation.start", "dictation.stop", "dictation.cancel", "dictation.openSettings", "dictation.audio",
            "transport.open", "transport.send", "transport.close", "transport.gesture", "transport.gesture.release",
            "chat.missing",
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
    /// The page host's transport queue bound. A caller that receives `false` from ``publish``
    /// must recover the page/transport; the provider never silently evicts an event.
    public static let maximumBufferedEvents = 8_192
    private static let replayBatchSize = 128

    /// The stream of host pushes (``AgentPageEvent``) the page subscribes to once its
    /// `cmuxAcpmuxBridge` is installed.
    public static let hostEvents = "cmux.agent.host.events"

    private let prepare: Prepare
    private var listeners: [UInt64: @MainActor (JSONValue) -> Void] = [:]
    /// Events published while the page host has no subscription (a reload or bridge gap). They
    /// stay in host order until the next page subscribes. A provider belongs to one
    /// ``AgentPaneView`` and is released with that view if no page returns, so this is a
    /// gap-lifetime queue rather than process-wide retention; a reconnect drains it once.
    private var bufferedEvents: [AgentPageEvent] = []
    /// The socket connection whose frames last reached the page. A fresh socket is an
    /// authoritative transport resync, so it clears an overflow latch left by the old socket.
    private var transportConnection: Int?
    /// Set when the bounded replay queue cannot retain a dropped envelope. The next publish
    /// returns false so the transport closes and the page performs a full resync; no event is
    /// silently evicted.
    private var deliveryOverflowed = false
    /// True when the provider's own gap queue, rather than a subscriber handoff, overflowed. A
    /// replacement socket may discard only this queue after its explicit resync signal.
    private var bufferedQueueOverflowed = false
    /// Subscribers whose replay queue reached the bound; a socket reconnect resets that stalled
    /// handoff and reapplies current replay state while keeping the subscription alive.
    private var overflowedPendingListeners: Set<UInt64> = []
    /// A subscriber's replay is held in one queue until its subscription reply has reached the
    /// page. Events arriving during that handoff append to the same queue instead of overtaking it.
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

    public init(prepare: @escaping Prepare) {
        self.prepare = prepare
    }

    /// Marks a newly opened acpmux socket. The page keeps this subscription across socket
    /// reconnects, so the overflow latch cannot wait for a WebView resubscribe to clear.
    public func transportDidOpen(_ connection: Int) {
        guard transportConnection != connection else { return }
        transportConnection = connection
        // Preserve partial gap queues across socket reconnects: they also contain commands and
        // chrome updates that transport cannot recreate. A full gap queue was already explicit
        // backpressure, so the replacement socket's authoritative resync may discard that queue.
        if bufferedQueueOverflowed { bufferedEvents.removeAll(keepingCapacity: true) }
        bufferedQueueOverflowed = false
        for id in overflowedPendingListeners {
            pendingEvents.removeValue(forKey: id)
            guard let listener = listeners[id] else { continue }
            for event in replay?() ?? [] { listener(event.data) }
        }
        overflowedPendingListeners.removeAll(keepingCapacity: true)
        deliveryOverflowed = false
    }

    public var eventsAfterSubscribeReply: Bool { true }

    public func eventDeliveryDropped(stream: String, data: JSONValue) {
        guard stream == Self.hostEvents,
              case .string(let kind)? = data["kind"] else { return }
        let value = data["value"] ?? .null
        guard bufferedEvents.count < Self.maximumBufferedEvents else {
            bufferedQueueOverflowed = true
            deliveryOverflowed = true
            return
        }
        bufferedEvents.append(AgentPageEvent(kind: kind, value: value))
    }

    /// Sends `event` to every subscribed page.
    @discardableResult
    public func publish(_ event: AgentPageEvent) -> Bool {
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
        for id in listeners.keys.sorted() {
            if let pending = pendingEvents[id] {
                guard pending.events.count - pending.next < Self.maximumBufferedEvents else {
                    deliveryOverflowed = true
                    overflowedPendingListeners.insert(id)
                    accepted = false
                    continue
                }
                pending.events.append(event)
            } else {
                listeners[id]?(event.data)
            }
        }
        return accepted
    }

    public var hasSubscribers: Bool { !listeners.isEmpty }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.hostEvents else { throw PageError.unknownOp(stream) }
        if deliveryOverflowed, listeners.isEmpty {
            // The transport already reported backpressure; its reconnect performs the authoritative
            // acpmux resync, while this page stream starts from current replay state.
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
        pendingEvents[id] = pending
        // Keep replay ahead of events emitted while the current-state closure runs. Those events
        // append to the pending queue because the subscription is already marked as handshaking.
        let replayEvents = self.replay?() ?? []
        pending.events.insert(contentsOf: replayEvents, at: pending.next)
        // The current state and any buffered events go after the subscribe reply that names the
        // subscription reaches the page. task-owner: one replay after the reply.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.flushPendingEvents(for: id)
        }
        return PageSubscription { [weak self] in self?.cancel(id: id) }
    }

    /// Replays in order after the page has the subscription id. Events that arrive while the
    /// callback runs append to `pendingEvents`, so they cannot overtake older buffered events.
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
            listener(event.data)
        }
        pending.compactDelivered()
        if pending.next < pending.events.count {
            // Yield between batches so a reconnect cannot monopolize the main actor.
            Task { @MainActor [weak self] in self?.flushPendingEvents(for: id) }
            return
        }
        pendingEvents.removeValue(forKey: id)
    }

    /// A page can disappear before its queued replay runs. Keep the not-yet-delivered suffix for
    /// the next page only when this was the last listener; another live page already received it.
    private func cancel(id: UInt64) {
        listeners.removeValue(forKey: id)
        overflowedPendingListeners.remove(id)
        guard let pending = pendingEvents.removeValue(forKey: id), listeners.isEmpty else { return }
        appendRequeued(pending.requeueRemaining())
    }

    private func requeuePendingEvents(for id: UInt64, pending: PendingEvents) {
        pendingEvents.removeValue(forKey: id)
        listeners.removeValue(forKey: id)
        overflowedPendingListeners.remove(id)
        guard listeners.isEmpty else { return }
        appendRequeued(pending.requeueRemaining())
    }

    private func appendRequeued(_ events: [AgentPageEvent]) {
        guard !events.isEmpty else { return }
        let available = Self.maximumBufferedEvents - bufferedEvents.count
        guard events.count <= available else {
            bufferedQueueOverflowed = true
            deliveryOverflowed = true
            return
        }
        // Events already buffered by a reset's onDrop callback precede this pending suffix.
        bufferedEvents.append(contentsOf: events)
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
