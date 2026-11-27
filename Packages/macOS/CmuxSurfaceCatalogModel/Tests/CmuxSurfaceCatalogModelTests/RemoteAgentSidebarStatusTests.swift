import CmuxSurfaceCatalogModel
import Testing

@Suite struct RemoteAgentSidebarStatusTests {
    @Test func daemonStatesMapToSidebarActivity() {
        #expect(RemoteAgentSidebarStatus(badge: .init(state: "working", source: "hook", agent: "claude"))
            == .init(statusKey: "cmux.remote.agent:claude_code", activity: .running))
        #expect(RemoteAgentSidebarStatus(badge: .init(state: "blocked", source: "hook", agent: "codex"))
            == .init(statusKey: "cmux.remote.agent:codex", activity: .needsInput))
        #expect(RemoteAgentSidebarStatus(badge: .init(state: "idle", source: "hook", agent: "codex"))?.activity == .idle)
        #expect(RemoteAgentSidebarStatus(badge: .init(state: "done", source: "hook", agent: "claude")) == nil)
        #expect(RemoteAgentSidebarStatus(badge: .init(state: "unknown", source: "hook", agent: "claude")) == nil)
    }

    @Test func slotKeyIsTheAdapterNotTheProvenance() {
        #expect(RemoteAgentSidebarStatus(badge: .init(state: "working", source: "hook"))?.statusKey
            == "cmux.remote.agent:agent")
        #expect(RemoteAgentSidebarStatus(badge: .init(state: "working", source: "claude-code"))?.statusKey
            == "cmux.remote.agent:claude_code")
        #expect(RemoteAgentSidebarStatus(badge: .init(state: "working", source: "plugin", agent: " OpenCode "))?.statusKey
            == "cmux.remote.agent:opencode")
        #expect(RemoteAgentSidebarStatus(badge: .init(state: "working", source: "hook", agent: "a b;c"))?.statusKey
            == "cmux.remote.agent:abc")
    }

    @Test func ownedKeysStayOutOfTheLocalHookSlots() {
        let status = RemoteAgentSidebarStatus(badge: .init(state: "working", source: "hook", agent: "claude"))
        #expect(status.map { RemoteAgentSidebarStatus.isOwnedStatusKey($0.statusKey) } == true)
        #expect(!RemoteAgentSidebarStatus.isOwnedStatusKey("claude_code"))
        #expect(!RemoteAgentSidebarStatus.isOwnedStatusKey("codex"))
    }

    @Test func workspaceSlotShowsTheMostUrgentTerminal() {
        let slots = RemoteAgentSidebarStatus.workspaceSlots([
            .init(statusKey: "cmux.remote.agent:claude_code", activity: .idle),
            .init(statusKey: "cmux.remote.agent:claude_code", activity: .needsInput),
            .init(statusKey: "cmux.remote.agent:claude_code", activity: .running),
            .init(statusKey: "cmux.remote.agent:codex", activity: .idle),
        ])
        #expect(slots == [
            "cmux.remote.agent:claude_code": .needsInput,
            "cmux.remote.agent:codex": .idle,
        ])
    }
}
