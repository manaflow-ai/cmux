import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// tab-switch-rewrite (u2873, a251's Cmd-T burst stalls): a tab switch changes its workspace's row
/// (the selected tab's title and kind), and the sidebar patches that row in place. With the
/// workspace's tabs listed (`showWorkspaceTabs`), the patch configured every tab row of the
/// workspace again, so each switch cost one row configure per tab. A patch configures the
/// workspace row and only the tab rows whose content changed.
@MainActor @Suite(.serialized) struct SidebarTabSwitchPatchTests {
    @Test(arguments: [10, 24])
    func aTabSwitchPatchConfiguresOnlyTheRowsItChanges(_ count: Int) async throws {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let id = WorkspaceID("ts-patch")
        let tabs = (0..<count).map { SidebarTab(id: TabID("ts-tab-\($0)"), title: "tab \($0)") }
        var ws = SidebarWorkspace(id: id, title: "tab 0")
        ws.tabs = tabs
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [.workspace(ws)])], activeWorkspaceID: id)
        model.showWorkspaceTabs = true // the tab-row code; no setting lists tabs any more
        let design = DesignSettings()
        let sidebar = SidebarView(model: model, design: design)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 1400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 1400)
        window.orderFrontRegardless()
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        let tabRows = sidebar.list.rowViews.keys.filter { if case .tab = $0 { true } else { false } }.count
        try #require(tabRows >= count / 2, "tab rows realized: \(tabRows)")
        _ = SidebarPerfCounters.report(reset: true)

        // Each switch: the row shows the newly selected tab's title; the tabs are the same.
        for index in 1..<count {
            var row = ws
            row.title = "tab \(index)"
            #expect(model.patchWorkspaces([row]))
        }
        let report = SidebarPerfCounters.report(reset: true)
        let switches = count - 1
        let configures = report["row_configures"] ?? 0
        print("SIDEBAR-TAB-SWITCH n=\(count) tabRows=\(tabRows) switches=\(switches) configures=\(configures) reloads=\(report["list_reloads"] ?? 0)")
        #expect((report["list_reloads"] ?? 0) == 0, "a tab switch laid the sidebar out again")
        #expect(configures <= switches, "\(switches) tab switches configured \(configures) rows (\(tabRows) tab rows shown)")

        // A tab whose own content changes (unread) is still drawn.
        var unread = ws
        unread.tabs[3].isUnread = true
        #expect(model.patchWorkspaces([unread]))
        #expect((SidebarPerfCounters.report(reset: true)["row_configures"] ?? 0) == 2, "the workspace row and the changed tab row")
    }
}
