import AppKit
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWindowRules

/// The hook identifies the transcript. The page receives a capability for this one chat:
/// neither a file path nor a writable agent session crosses the page bridge.
struct TerminalHistorySource: Equatable {
    let key: String
    let cwd: String?

    func read(_ method: AcpmuxHarnessMethod, environment: AcpmuxEnvironment,
              params: [String: any Sendable]) async throws -> CmuxNextSettings.JSONValue {
        var request = params
        request["key"] = key
        if let cwd { request["cwd"] = cwd }
        let data = try await environment.harness(method, params: request)
        return try CmuxNextSettings.JSONValue.parse(data)
    }
}

@MainActor
final class TerminalHistoryPage: InternalPageProvider {
    static let id = InternalPageID(rawValue: "terminal-history")
    let page = TerminalHistoryPage.id
    let symbol = "clock.arrow.circlepath"
    let title = String(localized: "terminalHistory.tab", defaultValue: "Earlier history", bundle: .module)
    private var sources: [String: TerminalHistorySource] = [:]
    private var views: [String: PageWebView] = [:]
    private weak var services: AppServices?

    init(services: AppServices) { self.services = services }

    static func chatKey(_ status: AgentStatus?) -> String? {
        guard let status, let session = status.harnessSessionID else { return nil }
        switch WindowRules().agentHarness(status.agent) {
        case "claude": return "claude-code:" + session
        case "codex": return "codex:" + session
        default: return nil
        }
    }

    static func open(_ source: TerminalHistorySource, in pane: PaneController) {
        let pages = pane.services.pages
        let provider: TerminalHistoryPage
        if let registered = pages.provider(id) as? TerminalHistoryPage { provider = registered }
        else { provider = TerminalHistoryPage(services: pane.services); pages.register(provider) }
        if let existing = pages.tabIDs(in: pane.paneKey).first(where: { provider.sources[$0]?.key == source.key }) {
            pages.reveal(existing, in: pane)
            return
        }
        // Keep the grant local to this window. A restored or remotely-created page carries no grant.
        let key = LocalPageTab.makeKey(id)
        provider.sources[key] = source
        pages.open(id, in: pane.paneKey, of: pane.daemon.store, after: pane.stripModel.selectedID?.rawValue,
                   window: pane.services.windowController(showing: pane), key: key)
        pane.apply(pane.snapshot())
        pages.reveal(key, in: pane)
    }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let source = sources[key], let services else { return NSView() }
        let provider = TerminalHistoryBridge(source: source, services: services)
        let descriptor = PageDescriptor(id: "cmux.terminal-history", resource: "terminal-history",
                                        namespaces: [TerminalHistoryBridge.namespace], ownsSearchField: true,
                                        followsChatZoom: true)
        let view = PageWebView(descriptor: descriptor, routes: [PageRoute(prefix: TerminalHistoryBridge.namespace, provider: provider)])
        views[key] = view
        return view
    }

    func tabClosed(_ key: String) {
        sources[key] = nil
        views.removeValue(forKey: key)?.close()
    }
}

@MainActor
private final class TerminalHistoryBridge: PageProvider {
    static let namespace = "cmux.terminal_history."
    let source: TerminalHistorySource
    private let environment: AcpmuxEnvironment?
    private let host: any AgentPaneHostProviding
    init(source: TerminalHistorySource, services: AppServices) {
        self.source = source
        environment = QuitAgents.environment(services)
        host = services.agentTabs.localSessionHost ?? services.agentTabs.host
    }

    func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        guard let environment else { throw PageError(code: "unavailable", message: String(localized: "terminalHistory.unavailable", defaultValue: "Chat history is unavailable.", bundle: .module)) }
        let method: AcpmuxHarnessMethod
        var request: [String: any Sendable] = [:]
        switch op {
        case Self.namespace + "page": method = .terminalTranscriptPage
        case Self.namespace + "find":
            guard let query = params["query"]?.stringValue else { throw PageError.invalidParams("query") }
            method = .terminalTranscriptFind
            request["query"] = query
        default: throw PageError.unknownOp(op)
        }
        if let before = params["before"], !before.isNull {
            guard let offset = before.intValue, offset >= 0 else { throw PageError.invalidParams("before") }
            request["before"] = offset
        }
        do {
            return try await source.read(method, environment: environment, params: request)
        } catch let error as AcpmuxRPCError where error.isUnreachable {
            try await host.prewarm()
            return try await source.read(method, environment: environment, params: request)
        }
    }
}
