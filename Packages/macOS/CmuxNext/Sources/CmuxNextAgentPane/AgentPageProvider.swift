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

    /// The stream of host pushes (``AgentPageEvent``) the page subscribes to once its
    /// `cmuxAcpmuxBridge` is installed.
    public static let hostEvents = "cmux.agent.host.events"

    private let prepare: Prepare
    private var listeners: [UInt64: @MainActor (JSONValue) -> Void] = [:]
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

    /// Sends `event` to every subscribed page.
    public func publish(_ event: AgentPageEvent) {
        for id in listeners.keys.sorted() { listeners[id]?(event.data) }
    }

    public var hasSubscribers: Bool { !listeners.isEmpty }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.hostEvents else { throw PageError.unknownOp(stream) }
        let id = nextListener
        nextListener += 1
        listeners[id] = onEvent
        // The current state, after the subscribe reply that names the subscription reaches the page.
        // task-owner: one replay after the reply; a cancelled subscription receives nothing
        Task { @MainActor [weak self] in
            guard let self, self.listeners[id] != nil else { return }
            for event in self.replay?() ?? [] { self.listeners[id]?(event.data) }
        }
        return PageSubscription { [weak self] in self?.listeners.removeValue(forKey: id) }
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
