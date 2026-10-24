import Testing
@testable import CmuxNextDaemon

/// Jump to Last Prompt (hq#1870 parity audit, P1 7): classic jumped to the
/// terminal whose agent the person last prompted, across workspaces. The store
/// keeps when each terminal's agent started a prompted turn, from the agent
/// reports the daemon already sends.
@MainActor
struct StoreLastPromptTests {
    private func store() -> DaemonStore {
        let store = DaemonStore()
        func workspace(_ id: UInt64) -> WorkspaceSnapshot {
            let pane = PaneSnapshot(id: PaneID(rawValue: id), tabs: [TabSnapshot(surface: SurfaceID(rawValue: id))])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id), key: nil, name: "w\(id)",
                                     screens: [ScreenSnapshot(id: ScreenID(rawValue: id), layout: .leaf(PaneID(rawValue: id)), panes: [pane])])
        }
        let workspaces = [workspace(1), workspace(2)]
        store.apply(snapshot: DaemonTree(workspaces: workspaces))
        return store
    }

    private func report(_ store: DaemonStore, _ surface: SurfaceID, _ state: AgentState, _ source: String, at ms: UInt64) {
        store.apply(.agentChanged(AgentStatus(surface: surface, state: state, source: source, agent: "claude", updatedAtMs: ms)))
    }

    @Test func promptedTurnsAreRecordedPerTab() {
        let store = store()
        #expect(store.agents.lastPromptBySurface[1] == nil)

        // A hook agent works only after UserPromptSubmit; a plugin agent starts working.
        report(store, 1, .working, "hook", at: 100)
        report(store, 2, .working, "plugin", at: 200)
        #expect(store.agents.lastPromptBySurface[1] == 100)
        #expect(store.agents.lastPromptBySurface[2] == 200)

        // An approval resumes the same turn, and a repeated report is not a new prompt.
        report(store, 2, .blocked, "plugin", at: 250)
        report(store, 2, .working, "plugin", at: 300)
        report(store, 2, .working, "plugin", at: 320)
        #expect(store.agents.lastPromptBySurface[2] == 200)

        // The next turn on each is a new prompt.
        report(store, 1, .idle, "hook", at: 400)
        report(store, 1, .working, "hook", at: 500)
        report(store, 2, .idle, "plugin", at: 600)
        report(store, 2, .working, "plugin", at: 700)
        #expect(store.agents.lastPromptBySurface[1] == 500)
        #expect(store.agents.lastPromptBySurface[2] == 700)

        // A reconnect re-seeds the agents with the roster's own times: the newest prompt stays.
        store.apply(agents: [AgentStatus(surface: 1, state: .working, source: "hook", agent: "claude", updatedAtMs: 450)])
        #expect(store.agents.lastPromptBySurface[1] == 500)
    }

    /// A hook agent that waited goes back to work on its next tool hook (#22995): the same
    /// turn with the same prompt, not a new one. A new prompt out of a wait still is one.
    @Test func aHookAgentResumingFromAWaitKeepsItsPrompt() {
        let store = store()
        func hook(_ state: AgentState, at ms: UInt64, prompt: String) {
            store.apply(.agentChanged(AgentStatus(surface: 1, state: state, source: "hook", agent: "claude",
                                                  updatedAtMs: ms, lastPrompt: prompt)))
        }
        hook(.working, at: 100, prompt: "ship it")
        hook(.blocked, at: 150, prompt: "ship it")
        hook(.working, at: 200, prompt: "ship it")
        #expect(store.agents.lastPromptBySurface[1] == 100)

        hook(.blocked, at: 250, prompt: "ship it")
        hook(.working, at: 300, prompt: "now the docs")
        #expect(store.agents.lastPromptBySurface[1] == 300)
    }
}
