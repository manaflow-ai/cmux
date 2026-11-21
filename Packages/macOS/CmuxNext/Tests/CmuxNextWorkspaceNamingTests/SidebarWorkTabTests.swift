import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar
import CoreGraphics
import Testing

/// The work tab a browser front tab yields its row's name to (hq#1957,
/// https://github.com/manaflow-ai/cmux/issues/22249): the work the row was
/// named for before the page opened, so the most recently focused pane that
/// shows a chat or terminal, not the first one the workspace stores.
@MainActor
struct SidebarWorkTabTests {
    /// Terminals `a` and `b` in their own panes and a browser page in a third,
    /// each pane focused at the given time.
    private static func workspace(a: UInt64, b: UInt64, page: UInt64) throws -> WorkspaceModel {
        let store = DaemonStore()
        let panes = [
            PaneSnapshot(id: 1, focusedAt: a, tabs: [TabSnapshot(surface: 1, kind: .pty, title: "a")]),
            PaneSnapshot(id: 2, focusedAt: b, tabs: [TabSnapshot(surface: 2, kind: .pty, title: "b")]),
            PaneSnapshot(id: 3, focusedAt: page, tabs: [TabSnapshot(surface: 3, kind: .browser, title: "PR", url: "https://github.com")]),
        ]
        let layout = LayoutNode.split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(1),
                                      b: .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(2), b: .leaf(3)))
        let screen = ScreenSnapshot(id: 1, layout: layout, panes: panes)
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "workspace-3", screens: [screen])]))
        return try #require(store.workspaces.first)
    }

    /// A page tab (Settings, a diff) gives the row no name, so the work tab passes over it.
    @Test func aPageTabIsNotWork() throws {
        let store = DaemonStore()
        var settings = TabSnapshot(surface: 2, kind: .conversation, title: "about:blank", url: "about:blank")
        settings.conversation = ConversationTabRef(page: "settings")
        let panes = [
            PaneSnapshot(id: 1, focusedAt: 1, tabs: [TabSnapshot(surface: 1, kind: .pty, title: "a")]),
            PaneSnapshot(id: 2, focusedAt: 2, tabs: [settings]),
            PaneSnapshot(id: 3, focusedAt: 3, tabs: [TabSnapshot(surface: 3, kind: .browser, title: "PR", url: "https://github.com")]),
        ]
        let layout = LayoutNode.split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(1),
                                      b: .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(2), b: .leaf(3)))
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "workspace-3",
                                                                        screens: [ScreenSnapshot(id: 1, layout: layout, panes: panes)])]))
        let workspace = try #require(store.workspaces.first)
        #expect(SidebarMapping.shared.faceTabs(workspace, selectedTab: { _ in nil }).work?.titleText == "a")
    }

    @Test func aPageInASplitYieldsToTheLastFocusedWork() throws {
        let laterB = try Self.workspace(a: 1, b: 2, page: 3)
        #expect(SidebarMapping.shared.faceTabs(laterB, selectedTab: { _ in nil }).front?.kind == .browser)
        #expect(SidebarMapping.shared.faceTabs(laterB, selectedTab: { _ in nil }).work?.titleText == "b")
        let laterA = try Self.workspace(a: 2, b: 1, page: 3)
        #expect(SidebarMapping.shared.faceTabs(laterA, selectedTab: { _ in nil }).work?.titleText == "a")
    }
}

/// The row's icon follows the tab last focused in the workspace (user 23802: "workspace favicon needs to
/// reflect the latest focused/interacted entity"): a page focused in a split beside a chat or terminal shows its
/// favicon, and focus back on that work drops it. The row's name still yields to the work (#22249).
@MainActor
struct SidebarWorkTabIconTests {
    private static let favicon: SidebarFavicon = {
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        return SidebarFavicon(context.makeImage()!)
    }()

    private static func workspace(_ panes: [PaneSnapshot]) throws -> WorkspaceModel {
        let store = DaemonStore()
        let layout: LayoutNode = panes.count == 1 ? .leaf(1)
            : .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(1), b: .leaf(2))
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "workspace-3",
                                                                        screens: [ScreenSnapshot(id: 1, layout: layout, panes: panes)])]))
        return try #require(store.workspaces.first)
    }

    private static func row(_ workspace: WorkspaceModel) -> SidebarWorkspace {
        SidebarMapping.shared.row(workspace, machine: .local, pageFace: { _, tab, _ in
            tab.kind == .browser ? .init(title: "Pull request", favicon: favicon) : nil
        })
    }

    private static let page = TabSnapshot(surface: 2, kind: .browser, title: "PR", url: "https://github.com")

    @Test func aFocusedPageBesideWorkShowsItsFavicon() throws {
        let row = try Self.row(Self.workspace([
            PaneSnapshot(id: 1, focusedAt: 1, tabs: [TabSnapshot(surface: 1, kind: .pty, title: "coordinator")]),
            PaneSnapshot(id: 2, focusedAt: 2, tabs: [Self.page]),
        ]))
        #expect(row.icon == .favicon(Self.favicon))
        // The page keeps its favicon in the row's tab list.
        #expect(row.tabs.first(where: { $0.kind == .browser })?.favicon == Self.favicon)
    }

    @Test func focusBackOnTheWorkDropsThePageFavicon() throws {
        let row = try Self.row(Self.workspace([
            PaneSnapshot(id: 1, focusedAt: 2, tabs: [TabSnapshot(surface: 1, kind: .pty, title: "coordinator")]),
            PaneSnapshot(id: 2, focusedAt: 1, tabs: [Self.page]),
        ]))
        #expect(row.icon == nil)
    }

    /// The window's own focus wins over the daemon's `focused_at`, which the app never writes (focus.md 2): a
    /// page opened in a split is stamped newest by the daemon, and a click back into the terminal must still
    /// drop its favicon (Leo 2026-10-21: "why did this turn into the githb favicon?").
    @Test func theWindowsFocusedPaneWinsOverTheDaemonsStamp() throws {
        let workspace = try Self.workspace([
            PaneSnapshot(id: 1, focusedAt: 1, tabs: [TabSnapshot(surface: 1, kind: .pty, title: "coordinator")]),
            PaneSnapshot(id: 2, focusedAt: 2, tabs: [Self.page]),
        ])
        let terminalPane = try #require(workspace.screens.first?.panes.first { $0.tabs.first?.kind == .pty })
        let pagePane = try #require(workspace.screens.first?.panes.first { $0.tabs.first?.kind == .browser })
        let memory = TabSelectionMemory()
        func row() -> SidebarWorkspace {
            SidebarMapping.shared.row(workspace, machine: .local, focusedPane: { memory.focusedPane(in: $0.id) },
                                      pageFace: { _, tab, _ in tab.kind == .browser ? .init(title: "PR", favicon: Self.favicon) : nil })
        }
        memory.focus(terminalPane.id, in: workspace.id)
        #expect(row().icon == nil)
        #expect(row().focusedTab?.rawValue == terminalPane.tabs.first?.id)
        memory.focus(pagePane.id, in: workspace.id)
        #expect(row().icon == .favicon(Self.favicon))
    }

    @Test func aWorkspaceOfPagesShowsItsPagesFavicon() throws {
        let row = try Self.row(Self.workspace([PaneSnapshot(id: 1, focusedAt: 1, tabs: [Self.page])]))
        #expect(row.icon == .favicon(Self.favicon))
    }
}
