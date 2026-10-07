import CmuxMobileHost
import CmuxMobileWire
import Testing

@Suite("Workspace projection diff")
struct WorkspaceDiffTests {
    let base = FakeDaemon.sample

    func ops(_ change: (inout MobileWorkspaceState) -> Void) -> [String] {
        var next = base
        change(&next)
        return WorkspaceDiff(from: base, to: next).changes.map(\.op)
    }

    @Test func noChangeNoEvents() {
        #expect(ops { _ in }.isEmpty)
    }

    @Test func workspaceMetadataAndShapeResendTheWorkspace() {
        #expect(ops { $0.workspaces[0].name = "renamed" } == ["workspace.upsert"])
        #expect(ops { $0.workspaces[0].panes[0].tabs.append(MobileTab(id: "tab_t2", kind: .browser, title: "docs")) } == ["workspace.upsert"])
        #expect(ops { $0.workspaces.append(MobileWorkspace(id: "ws_b2", name: "b", order: 1, panes: [])) } == ["workspace.upsert"])
    }

    @Test func removedWorkspace() {
        #expect(ops { $0.workspaces.removeAll() } == ["workspace.remove"])
    }

    @Test func tabTitleIsATabUpsertAndStatusIsAStatusSet() {
        #expect(ops { $0.workspaces[0].panes[0].tabs[0].title = "vim" } == ["workspace.tab.upsert"])
        #expect(ops { $0.workspaces[0].panes[0].tabs[0].status = .needsInput; $0.workspaces[0].panes[0].tabs[0].unread = 2 }
            == ["workspace.status.set"])
    }
}
