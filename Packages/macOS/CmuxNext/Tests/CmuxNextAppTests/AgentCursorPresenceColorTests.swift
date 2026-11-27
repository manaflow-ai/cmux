@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// A browser cursor takes the presence color of the agent whose terminal holds
/// its lease (cx-gg84), so it matches that agent's sidebar dot, tab chip and
/// pane tag; without the toggle, a terminal or the lease, it keeps its
/// session's palette color.
/// The lease names the public `term_…` id (`CMUX_TUI_TERMINAL_ID`), which
/// the tree carries as the tab's terminal resource id, not its host
/// `terminal_id`.
@MainActor
struct AgentCursorPresenceColorTests {
    @Test func aLeasedCursorTakesItsAgentsColorUntilTheLeaseEnds() {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_7")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        _ = store.apply(.agentPresenceChanged(AgentPresence(surface: 1, activity: .browsing, agent: "claude", session: "claude-1")))
        let colors = AgentCursorPresenceColors()
        let palette = colors.color(for: "s1", store: store, enabled: true)

        colors.leaseChanged(target: "W", session: "s1", terminal: "term_7")
        colors.leaseChanged(target: "X", session: "s2", terminal: "term_7")
        let agent = colors.color(for: "s1", store: store, enabled: true)
        #expect(agent != palette, "the agent's color, not the session palette")
        #expect(colors.color(for: "s2", store: store, enabled: true) == agent, "one agent, one color")
        #expect(colors.color(for: "s1", store: store, enabled: false) == palette, "off with the toggle")

        colors.leaseChanged(target: "W", session: nil, terminal: nil)
        #expect(colors.color(for: "s1", store: store, enabled: true) == palette, "the lease ended")
        colors.leaseChanged(target: "Y", session: "s3", terminal: nil)
        #expect(colors.color(for: "s3", store: store, enabled: true) == colors.color(for: "s3", store: nil, enabled: false))
    }
}
