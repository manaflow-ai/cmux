import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSidebar
import Testing

/// Lawrence 2026-11-07: "i pinned a workspace and it's name disappeared and went back to workspace-936". A workspace
/// nobody named keeps the daemon's `workspace-N`; its list row shows the auto name the page face gives
/// (`AppServices.sidebarPageFace`, `WorkspaceAutoNameReader.label`). Pinned, it leaves the list for a band item
/// (`SidebarWorkspaceItems`), which mapped the row with the face's favicon only, so its title fell back to
/// `workspace-936`. Pinning moves a row; it never renames it: the band item shows the title its list row shows.
@MainActor
struct PinnedWorkspaceKeepsTitleTests {
    /// A workspace named `name` (titled `title`) with one tab: a terminal in `cwd`, or a page at `url`.
    private static func workspace(name: String, title: String? = nil, cwd: String? = "/Users/dev/fun/cmux",
                                  url: String? = nil) throws -> WorkspaceModel {
        let store = DaemonStore()
        var tab = TabSnapshot(surface: 1, kind: url == nil ? .pty : .browser, cwd: url == nil ? cwd : nil)
        tab.url = url
        let pane = PaneSnapshot(id: 1, focusedAt: 1, tabs: [tab])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        var snapshot = WorkspaceSnapshot(id: 1, key: nil, name: name, screens: [screen])
        snapshot.title = title
        store.apply(snapshot: DaemonTree(workspaces: [snapshot]))
        return try #require(store.workspaces.first)
    }

    /// The face the list's rows read: the auto name `label` for a workspace nobody named (nil once it is named).
    private static func face(_ label: String?) -> (WorkspaceModel, TabModel, TabModel?) -> SidebarMapping.PageFace {
        { workspace, _, _ in .init(title: workspace.isUnnamed ? label : nil) }
    }

    @Test(arguments: [
        ("workspace-936", nil, "/Users/dev/fun/cmux", nil, "cmux", "cmux"),
        ("workspace-937", nil, nil, "https://github.com/manaflow-ai/cmux/pull/37866", "Sidebar face rules · PR #37866", "Sidebar face rules · PR #37866"),
        ("workspace-938", "Release notes", "/Users/dev/fun/cmux", nil, "cmux", "Release notes"),
        ("Pinned fix", nil, "/Users/dev/fun/cmux", nil, "cmux", "Pinned fix"),
    ] as [(String, String?, String?, String?, String, String)])
    func aPinnedWorkspaceKeepsTheTitleItsListRowShows(name: String, title: String?, cwd: String?, url: String?,
                                                      autoName: String, expected: String) throws {
        let workspace = try Self.workspace(name: name, title: title, cwd: cwd, url: url)
        let face = Self.face(autoName)
        let listRow = SidebarMapping.shared.row(workspace, machine: .local, pageFace: face)
        #expect(listRow.title == expected, "the list row reads \(listRow.title)")
        let pinned = SidebarWorkspaceItems.workspaceInfo(workspace, machine: .local, pageFace: face)
        #expect(pinned.title == listRow.title, "pinned, \(name) reads \(pinned.title); its list row read \(listRow.title)")
        #expect(pinned.workspaceRow?.title == listRow.title, "the pinned row's hover card reads \(pinned.workspaceRow?.title ?? "nil")")
        #expect(!WorkspaceModel.isNumberedDefaultName(pinned.title) || expected == pinned.title,
                "pinned, \(name) fell back to the daemon's default name \(pinned.title)")
    }
}
