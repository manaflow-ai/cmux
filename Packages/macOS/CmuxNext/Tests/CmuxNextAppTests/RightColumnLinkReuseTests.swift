import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTabs
import Testing

/// A link's identity belongs to the right column, even when its other row was used last.
@MainActor struct RightColumnLinkReuseTests {
    private static let address = "http://127.0.0.1:9/review#comment"

    private static func tree(matchingPane: UInt64, fragment: String = "comment") -> DaemonTree {
        let panes = (1...4).map { number -> PaneSnapshot in
            let id = UInt64(number)
            let tab = TabSnapshot(surface: SurfaceID(rawValue: id), kind: .browser, title: "Page",
                                  url: id == matchingPane ? "http://127.0.0.1:9/review#\(fragment)" : "http://127.0.0.1:9/other-\(id)")
            return PaneSnapshot(id: DaemonPaneID(rawValue: id), tabs: [tab])
        }
        let columns = [
            ColumnSnapshot(id: 10, width: 0.4, layout: .leaf(1)),
            ColumnSnapshot(id: 11, width: 0.4, layout: .split(id: nil, resourceID: nil, direction: .down,
                                                           ratio: 0.5, a: .leaf(2), b: .leaf(3))),
            ColumnSnapshot(id: 12, width: 0.2, layout: .leaf(4)),
        ]
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), columns: columns, panes: panes)
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen])])
    }

    @Test(arguments: [UInt64(2), 3])
    func aForegroundClickReusesEitherRowAndRecordsFocusReturn(matchingPane: UInt64) throws {
        let shown = try PaneCloseControllerTests.Shown(tree: Self.tree(matchingPane: matchingPane))
        defer { shown.end() }
        let source = try shown.controller(1)
        let matching = try shown.controller(matchingPane)
        let services = shown.services
        services.linkOpener.placement = { .splitRight }
        try shown.focus(matchingPane == 2 ? 3 : 2)
        try shown.focus(1)
        let tab = try #require(matching.pane.tabs.first)
        let before = shown.content.workspace.screens.flatMap(\.panes).flatMap(\.tabs).map(\.id)
        let url = try #require(URL(string: Self.address))

        #expect(services.linkOpener.openWeb(url, from: source, background: false, reusesTab: true))
        #expect(matching.stripModel.selectedID == StripTabID(tab.id))
        #expect(shown.content.focusedPane === matching)
        #expect(shown.content.workspace.screens.flatMap(\.panes).flatMap(\.tabs).map(\.id) == before,
                "Reusing the other row must not create a duplicate or a provisional tab")
        #expect(services.linkOpener.returnPane(closing: StripTabID(tab.id), in: matching, emptiesPane: true) === source)
    }

    @Test func aDifferentFragmentIsNotTheSameBrowserIdentity() throws {
        let shown = try PaneCloseControllerTests.Shown(tree: Self.tree(matchingPane: 3, fragment: "different-comment"))
        defer { shown.end() }
        shown.services.linkOpener.placement = { .splitRight }
        let source = try shown.controller(1)
        #expect(shown.services.linkOpener.browserTab(showing: try #require(URL(string: Self.address)), from: source) == nil)
    }

    @Test(arguments: [UInt64(1), 4])
    func sourceAndOtherColumnsAreNotReuseCandidates(matchingPane: UInt64) throws {
        let shown = try PaneCloseControllerTests.Shown(tree: Self.tree(matchingPane: matchingPane))
        defer { shown.end() }
        shown.services.linkOpener.placement = { .splitRight }
        let source = try shown.controller(1)
        #expect(shown.services.linkOpener.browserTab(showing: try #require(URL(string: Self.address)), from: source) == nil)
    }

    @Test func samePanePlacementDoesNotReuseAnotherRow() throws {
        let shown = try PaneCloseControllerTests.Shown(tree: Self.tree(matchingPane: 3))
        defer { shown.end() }
        shown.services.linkOpener.placement = { .samePane }
        let source = try shown.controller(1)
        #expect(shown.services.linkOpener.browserTab(showing: try #require(URL(string: Self.address)), from: source) == nil)
    }

    @Test func aMatchingPageInAnotherWorkspaceWindowIsNotReused() throws {
        var tree = Self.tree(matchingPane: 4)
        let tab = TabSnapshot(surface: 5, kind: .browser, title: "Other workspace", url: Self.address)
        let screen = ScreenSnapshot(id: 2, layout: .leaf(5), panes: [PaneSnapshot(id: 5, tabs: [tab])])
        tree.workspaces.append(WorkspaceSnapshot(id: 2, key: nil, name: "w2", screens: [screen]))
        let shown = try PaneCloseControllerTests.Shown(tree: tree)
        defer { shown.end() }
        let model = try #require(shown.services.daemon.store.workspaces.last)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w2","workspace_key":"w2"}"#.utf8))
        let state = WindowState(record: record)
        let other = WorkspaceContentController(workspace: model, daemon: shown.services.daemon,
                                               services: shown.services, state: state)
        defer { withExtendedLifetime(state) { other.teardown() } }
        other.applyCurrent()
        shown.services.linkOpener.placement = { .splitRight }
        let source = try shown.controller(1)
        #expect(shown.services.linkOpener.browserTab(showing: try #require(URL(string: Self.address)), from: source) == nil)
    }
}
