import CmuxNextDaemon
import CmuxNextSidebar
import Testing
@testable import CmuxNextBridge

@MainActor
struct SidebarMappingTests {
    @Test func loneMachineSectionListsWorkspacesInDaemonOrder() throws {
        let store = try BridgeFixture.store()
        let machine = SidebarMachine(id: .local, name: "Mac", kind: .local)
        let sections = SidebarMapping.sections(store.sidebarSections, machine: machine)
        #expect(sections.count == 1)
        #expect(sections[0].workspaces.map(\.title) == ["beta", "gamma"])
        // One unread marker on the first tab of beta.
        #expect(sections[0].workspaces[0].unread == .count(1))
    }

    @Test func reportedStatusIsTheLiveBlockAndCwdStaysPassive() throws {
        let store = try BridgeFixture.store()
        let machine = SidebarMachine(id: .local, name: "Mac", kind: .local)
        let beta = try #require(store.sidebarSections.flatMap(\.workspaces).first { $0.displayName == "beta" })
        let snapshot = WorkspaceStatusSnapshot(
            workspaceID: "ws_beta",
            entries: [.init(key: "build", text: "Running", icon: "hammer", color: "#FF8800"),
                      .init(key: "lint", text: "  ", color: "green")],
            progress: .init(value: 0.5, label: "Tests"),
            logCount: 3,
            lastLog: .init(level: "warning", text: "2 skipped")
        )
        let sections = SidebarMapping.sections(store.sidebarSections, machine: machine) { $0 === beta ? snapshot : nil }
        let mappedBeta = try #require(sections[0].workspaces.first { $0.title == "beta" })
        let status = try #require(mappedBeta.liveStatus)
        #expect(status.entries.map(\.displayText) == ["Running", "lint"])
        #expect(status.entries.map(\.tint) == [.rgba(0xFF88_00FF), .palette(.green)])
        #expect(status.entries[0].icon == "hammer")
        #expect(status.progress == .init(value: 0.5, label: "Tests"))
        #expect(status.log == .init(level: .warning, text: "2 skipped"))
        // The cwd never becomes a status line on its own.
        let plain = SidebarMapping.sections(store.sidebarSections, machine: machine)
        for ws in plain[0].workspaces { #expect(ws.liveStatus == nil) }
        #expect(plain[0].workspaces.first { $0.title == "beta" }?.subtitle == mappedBeta.subtitle)
    }

    @Test func clearedStatusDrawsNothingAndUnknownLevelsReadAsInfo() {
        let empty = SidebarMapping.status(WorkspaceStatusSnapshot(workspaceID: "ws_a"))
        #expect(empty.isEmpty)
        let odd = SidebarMapping.status(WorkspaceStatusSnapshot(workspaceID: "ws_a", logCount: 1,
                                                                lastLog: .init(level: "trace", text: "x")))
        #expect(odd.log?.level == .info)
    }

    @Test func dropPositionMapsToRootIndexAfterRemoval() {
        let rows = ["a", "b", "c", "d"].map { SidebarWorkspace(id: SidebarWorkspaceID($0), title: $0) }
        let machine = SidebarMachine(id: .local, name: "Mac", kind: .local)
        let sections = [SidebarRowSection(kind: .machine(machine), nodes: rows.map(SidebarNode.workspace))]
        let position = { (index: Int) in DropPosition(section: .machine(.local), index: index) }
        // Move "a" to after "c": remaining b c d, index 2 -> before d -> root 2.
        #expect(WorkspaceOrdering.rootIndex(for: position(2), moving: [SidebarWorkspaceID("a")], in: sections) == 2)
        #expect(WorkspaceOrdering.rootIndex(for: position(3), moving: [SidebarWorkspaceID("a")], in: sections) == 3)
        #expect(WorkspaceOrdering.rootIndex(for: position(0), moving: [SidebarWorkspaceID("d")], in: sections) == 0)
    }
}
