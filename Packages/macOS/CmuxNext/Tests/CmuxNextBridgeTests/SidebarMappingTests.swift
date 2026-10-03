import CmuxNextDaemon
import CmuxNextSidebar
import Testing
@testable import CmuxNextBridge

@MainActor
struct SidebarMappingTests {
    @Test func loneMachineSectionListsWorkspacesInDaemonOrder() throws {
        let store = try BridgeFixture.store()
        let machine = SidebarMachine(id: .local, name: "Mac", kind: .local)
        let sections = SidebarMapping.shared.sections(store.sidebarSections, machine: machine)
        #expect(sections.count == 1)
        #expect(sections[0].workspaces.map(\.title) == ["beta", "gamma"])
        // One unread marker on the first tab of beta.
        #expect(sections[0].workspaces[0].unread == .count(1))
    }

    /// The daemon's workspace status is the live line and its progress the
    /// bar; without a status, a terminal's parsed OSC 9;4 progress shows.
    @Test func daemonStatusIsTheLiveLineAndCwdStaysPassive() throws {
        let store = try BridgeFixture.store()
        let machine = SidebarMachine(id: .local, name: "Mac", kind: .local)
        // The cwd never becomes a second line on its own.
        let plain = SidebarMapping.shared.sections(store.sidebarSections, machine: machine)
        for ws in plain[0].workspaces { #expect(ws.liveDetail == nil && ws.progress == nil) }

        let beta = try #require(store.sidebarSections.flatMap(\.workspaces).first { $0.displayName == "beta" })
        let terminal = try #require(beta.screens.flatMap(\.panes).flatMap(\.tabs).first?.terminalResourceID)
        let betaID = try #require(beta.resourceID)
        var state = SessionStateMirror()
        state.workspaceStatus[betaID] = WorkspaceStatus(workspaceID: betaID, entries: [.init(key: "agent", text: "Running")],
                                                        progress: .init(value: 0.5))
        state.terminalProgress[terminal] = TerminalProgressReport(state: .error, value: 30)
        store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .sessionState(.snapshot(state)))])

        let mapped = { try #require(SidebarMapping.shared.sections(store.sidebarSections, machine: machine)[0].workspaces.first { $0.title == "beta" }) }
        #expect(try mapped().status == "Running")
        #expect(try mapped().liveDetail == "Running")
        #expect(try mapped().progress == SidebarProgress(value: 0.5))
        #expect(try mapped().subtitle == plain[0].workspaces.first { $0.title == "beta" }?.subtitle)

        // Without a reported progress, the terminal's parsed one shows.
        state.workspaceStatus[betaID]?.progress = nil
        store.apply(batch: [DaemonEventEnvelope(sequence: 2, event: .sessionState(.snapshot(state)))])
        #expect(try mapped().progress == SidebarProgress(value: 0.3, isError: true))
    }

    @Test func dropPositionMapsToRootIndexAfterRemoval() {
        let rows = ["a", "b", "c", "d"].map { SidebarWorkspace(id: SidebarWorkspaceID($0), title: $0) }
        let machine = SidebarMachine(id: .local, name: "Mac", kind: .local)
        let sections = [SidebarRowSection(kind: .machine(machine), nodes: rows.map(SidebarNode.workspace))]
        let position = { (index: Int) in DropPosition(section: .machine(.local), index: index) }
        // Move "a" to after "c": remaining b c d, index 2 -> before d -> root 2.
        #expect(WorkspaceOrdering.shared.rootIndex(for: position(2), moving: [SidebarWorkspaceID("a")], in: sections) == 2)
        #expect(WorkspaceOrdering.shared.rootIndex(for: position(3), moving: [SidebarWorkspaceID("a")], in: sections) == 3)
        #expect(WorkspaceOrdering.shared.rootIndex(for: position(0), moving: [SidebarWorkspaceID("d")], in: sections) == 0)
    }
}
