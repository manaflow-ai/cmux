public import CmuxNextPages
public import CmuxNextSettings
public import Foundation

public extension PageDescriptor {
    /// The agent pane, and with it the new tab page (react-pages.md, agent pane move). It reaches
    /// only its own `cmux.agent.*` ops; the app actions it may run are checked by
    /// ``AgentPaneModel`` (`cmux.agent.action.run`), so it lists no shared native op.
    /// It opens no connection of its own (the host's native transport, AgentPaneTransport, carries
    /// acpmux; the Debug dev loop loads a Vite page in the legacy host, which sends no header), shows
    /// loopback previews and render cards (AgentPaneRenderFrame) in frames, and runs only its own script files, no inline script. The page's
    /// meta CSP says the same (build-agent-pane-web.sh; AgentPageCSPAlignmentTests); the host runs the
    /// user's registry.js through evaluateJavaScript, which the CSP does not govern.
    static let agent = PageDescriptor(
        id: "cmux.agent", resource: "agent-pane", namespaces: [AgentPageOps.namespace],
        csp: PageCSP(connect: ["'none'"],
                     frame: [AgentPaneRenderFrame.source, "http://localhost:*", "http://127.0.0.1:*", "https://localhost:*", "https://127.0.0.1:*"],
                     inlineScript: false))
}

/// The `cmux.agent.*` ops: one per method of the old `agentSession` bridge, with the same params.
/// The op name is the method name, except the two renamed for the namespace.
public nonisolated struct AgentPageOps {
    public nonisolated init() {}
    public static let namespace = "cmux.agent."

    /// Op suffix to the old bridge method that ``AgentPaneRequest`` parses.
    static let methods: [String: String] = {
        var methods = Dictionary(uniqueKeysWithValues: [
            "pane.checkpointAvailability", "pane.framePacing", "pane.painted", "pane.renderRate", "pane.saveLog",
            "chat.readDraft", "chat.writeDraft",
            "tab.open", "tab.typeAhead", "tab.jump", "tab.setDefaultKind",
            "newTab.remember", "newTab.inputReady", "newTab.touched", "shortcut.edit", "action.run", "file.open", "browser.open",
            "project.list", "project.browse", "workspace.chooseFolder", "onboarding.importAndSync", "app.action",
            "quick.dismiss", "quick.openInWindow", "pane.action", "pane.tabState",
            "shell.run", "shell.read", "shell.stop",
            "git.diff", "git.status", "git.githubRepository", "file.search", "git.checkpoint.diff", "turn.undo",
            "dictation.toggle", "dictation.start", "dictation.stop", "dictation.cancel", "dictation.openSettings",
            "transport.open", "transport.send", "transport.close", "transport.gesture", "transport.gesture.release",
        ].map { ($0, $0) })
        for method in AgentPaneReplyRequest.methods { methods[method] = method }
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
        let request = AgentPaneRequest(body: ["method": method, "params": params.foundationObject])
        if case .unsupported = request { throw PageError.invalidParams(op) }
        guard let model = prepare(request) else { throw PageError.closed }
        return try Self.value(of: await model.respond(to: request))
    }

    /// The value of an ``AgentPaneReply``, or its failure as a ``PageError``. The model's code and
    /// message are kept; its `origin` and `details` travel in the error's details.
    nonisolated static func value(of reply: [String: Any]) throws -> JSONValue {
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
