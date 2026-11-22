@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// Duplicate Workspace captures the layout (splits, stacks, tabs) and can
/// leave browser tabs out; a duplicate never reuses a terminal.
struct WorkspaceBlueprintTests {
    typealias Node = WorkspaceBlueprint.Node
    typealias Tab = WorkspaceBlueprint.Tab

    static let tabs: [PaneID: [Tab]] = [
        1: [.terminal(cwd: "/src/a"), .browser(url: "https://a.test", engine: .cef)],
        2: [.browser(url: "https://b.test", engine: nil)],
        3: [.terminal(cwd: "/src/c")],
    ]

    @Test func captureKeepsTheSplitTreeAndTabs() {
        let layout = LayoutNode.split(id: nil, direction: .right, ratio: 0.3, a: .leaf(1),
                                      b: .split(id: nil, direction: .down, ratio: 0.6, a: .leaf(2), b: .leaf(3)))
        let node = Node.capture(layout) { Self.tabs[$0] ?? [] }
        #expect(node == .split(direction: .right, ratio: 0.3, a: .pane(Self.tabs[1]!),
                               b: .split(direction: .down, ratio: 0.6, a: .pane(Self.tabs[2]!), b: .pane(Self.tabs[3]!))))
    }

    @Test func aStackBecomesEqualVerticalSplits() {
        let node = Node.capture(.stack(panes: [1, 2, 3], expanded: 2)) { Self.tabs[$0] ?? [] }
        #expect(node?.paneCount == 3)
        if case .split(.down, let ratio, _, .split(.down, let inner, _, _))? = node {
            #expect(abs(ratio - 1.0 / 3) < 0.0001)
            #expect(abs(inner - 0.5) < 0.0001)
        } else {
            Issue.record("expected nested vertical splits, got \(String(describing: node))")
        }
    }

    @Test func panesWithoutTabsAreLeftOut() {
        let node = Node.capture(.split(id: nil, direction: .right, ratio: 0.5, a: .leaf(1), b: .leaf(99))) { Self.tabs[$0] ?? [] }
        #expect(node == .pane(Self.tabs[1]!))
    }

    @Test func withoutBrowserTabsCollapsesPagesOnlyPanes() {
        let root = Node.split(direction: .right, ratio: 0.3, a: .pane(Self.tabs[1]!), b: .pane(Self.tabs[2]!))
        let blueprint = WorkspaceBlueprint(name: "w", screens: [.init(name: nil, columns: [.init(width: nil, root: root)])])
        let terminals = blueprint.withoutBrowserTabs(fallbackDirectory: "/tmp")
        #expect(terminals.screens.first?.columns.first?.root == .pane([.terminal(cwd: "/src/a")]))
        #expect(terminals.firstDirectory == "/src/a")
    }

    @Test func withoutBrowserTabsKeepsOneTerminalWhenOnlyPagesWereOpen() {
        let blueprint = WorkspaceBlueprint(name: "w", screens: [.init(name: nil, columns: [.init(width: nil, root: .pane(Self.tabs[2]!))])])
        #expect(blueprint.withoutBrowserTabs(fallbackDirectory: "/tmp").screens.first?.columns.first?.root == .pane([.terminal(cwd: "/tmp")]))
    }

    @Test func iconIsASymbolNameOrOneEmoji() {
        #expect(WorkspaceIconValue.isValid("star.fill"))
        #expect(WorkspaceIconValue.isValid("🚀"))
        #expect(WorkspaceIconValue.isValid("👩‍💻"))
        #expect(!WorkspaceIconValue.isValid("🚀🚀"))
        #expect(!WorkspaceIconValue.isValid("not a symbol"))
        #expect(!WorkspaceIconValue.isValid(""))
    }

    /// Coordinator decision 2026-09-30: Duplicate Workspace copies each
    /// browser tab's browser profile.
    @MainActor @Test func captureKeepsEachBrowserTabsProfile() throws {
        let work = "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
        let tabs = [
            #"{"kind":"browser","name":"","surface":9,"dead":false,"browser_renderer":"frontend","browser_engine":"cef","url":"https://a.test/","browser_profile_id":"\#(work)"}"#,
            #"{"kind":"browser","name":"","surface":10,"dead":false,"browser_renderer":"frontend","browser_engine":"webkit","url":"https://b.test/"}"#,
        ]
        let store = DaemonStore()
        store.apply(snapshot: try BrowserRecordMoveTests.tree(pane: 3, tab: tabs.joined(separator: ",")))
        let workspace = try #require(store.workspaces.first)
        let blueprint = WorkspaceBlueprint(workspace)
        #expect(blueprint.screens.first?.columns.first?.root == .pane([
            .browser(url: "https://a.test/", engine: .cef, profile: work),
            .browser(url: "https://b.test/", engine: .webkit, profile: nil),
        ]))
    }
}
