import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// u9786 (2026-10-21): "right click workspace also feels laggy?" with 150+ workspaces. The
/// workspace menu is built on the right-click, on the main thread, before it shows; it must fit in
/// one frame. Host-independent: the menu draws only the rows that show when it opens (its own),
/// not every row of every submenu. The build time is printed for the report and checked loosely.
@MainActor
struct WorkspaceMenuOpenCostTests {
    @Test func theWorkspaceMenuDrawsOnlyItsOwnRowsWhenItOpens() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        var nodes: [SidebarNode] = (0..<20).map { group in
            .group(SidebarGroup(id: GroupID("g\(group)"), name: "Group \(group)", color: .blue,
                                workspaces: (0..<5).map { SidebarWorkspace(id: WorkspaceID("g\(group)-w\($0)"), title: "grouped \($0)") }))
        }
        nodes += (0..<150).map { .workspace(SidebarWorkspace(id: WorkspaceID("w\($0)"), title: "workspace-\($0)")) }
        let first = WorkspaceID("w0")
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: first)
        let scope = ThemeScope(level: .room)

        var times: [Double] = []
        var menu: NSMenu?
        for _ in 0..<20 {
            let start = ContinuousClock.now
            menu = SidebarContextMenus.menu(for: .workspaces([first]), model: model, services: services, scope: scope)
            times.append((ContinuousClock.now - start) / .milliseconds(1))
        }
        let built = try #require(menu)
        times.sort()
        print("workspace menu build at 250 workspaces: p50 \(times[times.count / 2]) ms, max \(times.last ?? 0) ms (first \(times.first ?? 0))")

        func drawn(_ menu: NSMenu) -> Int {
            menu.items.reduce(0) { $0 + ($1.view is ThemedMenuRowView ? 1 : 0) + ($1.submenu.map(drawn) ?? 0) }
        }
        let own = built.items.filter { $0.view is ThemedMenuRowView }.count
        #expect(drawn(built) == own, "the menu drew \(drawn(built)) rows to open; \(own) show")
        #expect(times[times.count / 2] < 50, "building the workspace menu took \(times[times.count / 2]) ms at the median")
    }
}
