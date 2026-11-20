import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileLive

/// Duplicate Workspace and Duplicate Workspace Without Browser Tabs from a phone: the Mac's
/// blueprint (screens, columns, splits, tabs in their folders, pages) from the Mac's tree.
@Suite struct DuplicateWorkspaceTests {
    typealias Blueprint = LiveWorkspaceCreationBackend.DuplicateBlueprint

    static func workspace(layout: WorkspaceLayout?) -> Workspace {
        let tabs = [
            WorkspaceTab(id: "s1", kind: .terminal, title: "zsh", subtitle: "~/p"),
            WorkspaceTab(id: "s2", kind: .agent, title: "Claude"),
            WorkspaceTab(id: "s3", kind: .browser, title: "Docs", url: URL(string: "https://example.com/a")),
            WorkspaceTab(id: "s4", kind: .browser, title: "File", url: URL(string: "file:///etc/hosts")),
            WorkspaceTab(id: "s5", kind: .terminal, title: "build"),
            WorkspaceTab(id: "s6", kind: .terminal, title: "logs", subtitle: "/var/log"),
        ]
        var ws = Workspace(id: "w", macID: "m", title: "api", directory: "~/p", tabs: tabs, lastActivityAt: Date(), colorHex: "blue", icon: "star")
        ws.layout = layout
        return ws
    }

    /// A split screen (s1 + s2 | s3 + s4 stacked over s5) and a second screen with two columns.
    static let layout = WorkspaceLayout(screens: [
        WorkspaceLayout.Screen(
            id: 1, name: "main", isActive: true,
            panes: [WorkspaceLayout.Pane(id: 10, tabIDs: ["s1", "s2"]), WorkspaceLayout.Pane(id: 11, tabIDs: ["s3", "s4"]),
                    WorkspaceLayout.Pane(id: 12, tabIDs: ["s5"])],
            root: .split(id: 100, axis: .horizontal, ratio: 0.3, first: .pane(10),
                         second: .split(id: 101, axis: .vertical, ratio: 0.6, first: .pane(11), second: .pane(12))),
            columns: []),
        WorkspaceLayout.Screen(
            id: 2, name: "logs", isActive: false,
            panes: [WorkspaceLayout.Pane(id: 20, tabIDs: ["s6"]), WorkspaceLayout.Pane(id: 21, tabIDs: ["s2"])],
            root: nil,
            columns: [WorkspaceLayout.Column(width: 0.5, root: .pane(20)),
                      WorkspaceLayout.Column(width: 0.4, dock: .init(edge: .right), root: .pane(21))]),
    ])

    @Test func theCopyKeepsScreensColumnsSplitsAndFolders() {
        let blueprint = LiveWorkspaceCreationBackend.duplicateBlueprint(Self.workspace(layout: Self.layout),
                                                                        directories: ["s1": "/Users/x/p"], browsers: true)
        #expect(blueprint.screens == [
            Blueprint.Screen(name: "main", columns: [Blueprint.Column(width: nil, root: .split(
                axis: .horizontal, ratio: 0.3, first: .pane([.terminal(folder: "/Users/x/p")]),
                second: .split(axis: .vertical, ratio: 0.6, first: .pane([.browser(url: "https://example.com/a")]),
                               second: .pane([.terminal(folder: nil)]))))]),
            // The dock's chat is not copied (the Mac copies no conversation).
            Blueprint.Screen(name: "logs", columns: [Blueprint.Column(width: 0.5, root: .pane([.terminal(folder: "/var/log")]))]),
        ])
    }

    @Test func withoutBrowserTabsAPaneOfPagesGoesAndItsSplitCollapses() {
        let blueprint = LiveWorkspaceCreationBackend.duplicateBlueprint(Self.workspace(layout: Self.layout),
                                                                        directories: [:], browsers: false)
        #expect(blueprint.screens.first?.columns.first?.root == .split(
            axis: .horizontal, ratio: 0.3, first: .pane([.terminal(folder: "~/p")]), second: .pane([.terminal(folder: nil)])))
        #expect(blueprint.tabCount == 3)
    }

    @Test func noLayoutIsOnePaneAndNothingLeftIsOneTerminal() {
        let flat = LiveWorkspaceCreationBackend.duplicateBlueprint(Self.workspace(layout: nil), directories: [:], browsers: true)
        #expect(flat.screens.map(\.columns.first?.root) == [.pane([
            .terminal(folder: "~/p"), .browser(url: "https://example.com/a"), .terminal(folder: nil), .terminal(folder: "/var/log"),
        ])])
        var pages = Self.workspace(layout: nil)
        pages.tabs = pages.tabs.filter { $0.kind == .browser }
        let empty = LiveWorkspaceCreationBackend.duplicateBlueprint(pages, directories: [:], browsers: false)
        #expect(empty.screens.map(\.columns.first?.root) == [.pane([.terminal(folder: nil)])])
    }
}
