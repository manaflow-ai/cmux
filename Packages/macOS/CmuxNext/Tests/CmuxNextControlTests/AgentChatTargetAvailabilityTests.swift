import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Testing

/// `cmux agent set-model --target pane:<id>` (and `tab:<id>`) used to be refused
/// "not available in the current context" when no agent chat had the keyboard:
/// `action.run` checked the action's `agentPaneFocused` requirement against the
/// focus and the target's kind alone, before the registry's target facts
/// (`ActionRegistry.targetContext`) could supply it, so only `agent-chat:<session>`
/// reached the handler. The router now reads the agent chat a pane or tab target
/// shows from the topology first (`ControlCatalog.impliedFacts`), then checks.
@MainActor
@Suite struct AgentChatTargetAvailabilityTests {
    /// pane-chat shows agent chat sess-1 (tab-chat); pane-term, which has the
    /// focus, shows a terminal and holds a second chat, tab-chat-2, behind it.
    static func topology() -> ControlTopology {
        var topology = ControlTopology()
        topology.isLoaded = true
        topology.daemonState = "connected"
        var chat = ControlTabInfo(id: "tab-chat", surface: "21", kind: "terminal", title: "Chat")
        chat.agentSessionID = "sess-1"
        var behind = ControlTabInfo(id: "tab-chat-2", surface: "23", kind: "terminal", title: "Other chat")
        behind.agentSessionID = "sess-2"
        let terminal = ControlTabInfo(id: "tab-term", surface: "22", kind: "terminal", title: "zsh", terminalID: "term-a")
        let chatPane = ControlPaneInfo(id: "pane-chat", handle: "5", selectedTabID: "tab-chat", tabs: [chat])
        let termPane = ControlPaneInfo(id: "pane-term", handle: "6", selectedTabID: "tab-term", tabs: [terminal, behind])
        topology.workspaces = [ControlWorkspaceInfo(id: "ws-1", handle: "1", name: "Main",
                                                    screens: [ControlScreenInfo(id: "screen-1", handle: "2", panes: [chatPane, termPane])])]
        topology.windows = [ControlWindowInfo(id: "win-1", workspaceID: "ws-1", isKey: true, isVisible: true, focusedPaneID: "pane-term")]
        return topology
    }

    /// Runs Set Agent Chat Model with `target` through the real registry and
    /// bridge, nothing focused. The registry's target facts stand in for the
    /// App's (WorkspaceSetVerbs): a pane or tab that shows a chat.
    func run(_ target: String) async -> (Result<JSONValue, ControlError>, ActionInvocation?) {
        let registry = ActionRegistry.standard()
        var seen: ActionInvocation?
        registry.bind("agentPane.setModel", invoke: { seen = $0 })
        registry.targetContext = { invocation in
            ["pane-chat", "tab-chat", "tab-chat-2"].contains(invocation.target?.id ?? "") ? .agentPaneFocused : []
        }
        let bridge = RegistryControlBridge(registry: registry)
        let router = ControlRouter(identity: testIdentity(), executor: bridge, settings: nil, configuration: .loadTolerant)
        router.updateCatalog(RegistryControlBridge.catalog(from: registry))
        let topology = Self.topology()
        router.snapshots.publish { $0.topology = topology }
        let result = await router.handle(ControlRequest(id: "1", method: "action.run", params: [
            "action": "agentPane.setModel", "target": .string(target), "args": ["model": "opus"],
        ]))
        return (result, seen)
    }

    func expectRan(_ target: String, kind: ActionTargetKind, id: String,
                   sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let (result, seen) = await run(target)
        _ = try result.get()
        #expect(seen?.target?.kind == kind, "\(target)", sourceLocation: sourceLocation)
        #expect(seen?.target?.id == id, "\(target)", sourceLocation: sourceLocation)
        #expect(seen?["model"]?.stringValue == "opus", "\(target)", sourceLocation: sourceLocation)
    }

    @Test func aPaneTargetShowingAChatRunsWithNoChatFocused() async throws {
        try await expectRan("pane:pane-chat", kind: .pane, id: "pane-chat")
    }

    @Test func aTabTargetThatIsAChatRunsWithNoChatFocused() async throws {
        try await expectRan("tab:tab-chat", kind: .tab, id: "tab-chat")
    }

    @Test func aTabTargetRunsForAChatBehindAnotherTab() async throws {
        try await expectRan("tab:tab-chat-2", kind: .tab, id: "tab-chat-2")
    }

    @Test func anAgentChatTargetStillRuns() async throws {
        try await expectRan("agent-chat:sess-1", kind: .agentChat, id: "sess-1")
    }

    @Test func aPaneOrTabTargetShowingNoChatIsStillRefused() async {
        for target in ["pane:pane-term", "tab:tab-term"] {
            let (result, seen) = await run(target)
            guard case .failure(let error) = result else {
                Issue.record("\(target): expected unavailable, got \(result)")
                continue
            }
            #expect(error.code == "unavailable", "\(target)")
            #expect(error.data?["not_run"] == true, "\(target)")
            #expect(seen == nil, "\(target)")
        }
    }

    @Test func impliedFactsReadTheChatAPaneShowsOrATabIs() {
        let topology = Self.topology()
        func facts(_ kind: String, _ id: String) -> ActionContext {
            ControlCatalog.impliedFacts(of: ControlTargetRef(kind: kind, id: id), in: topology)
        }
        #expect(facts("pane", "pane-chat") == .agentPaneFocused)
        #expect(facts("pane", "pane-term") == [], "its selected tab is a terminal; the chat behind it is not shown")
        #expect(facts("tab", "tab-chat-2") == .agentPaneFocused)
        #expect(facts("tab", "tab-term") == [])
        #expect(facts("workspace", "ws-1") == [])
    }
}
