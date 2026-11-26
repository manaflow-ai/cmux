import AppKit
@testable import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// The user, 2026-11-19 (msg 40501): "vault h1 h2 is pinned workspace but it shows gh logo instead of the pin logo".
/// A workspace with no icon of its own takes its shown tab's favicon as its row icon (the GitHub mark of a pull request
/// page), and the pinned row drew that favicon in the pin's place as if it were the workspace's own icon
/// (`SidebarPinnedRowLeading.ownIcon`). Leo 2026-11-23 (ask c-b5d3e0efb6: "it puts a symbol at the left. immediately
/// questionable") took the pin off pinned rows: a pinned row now leads exactly as its list row does, so it shows the
/// favicon its list row shows, and no pin.
@MainActor @Suite(.serialized, .closesItsWindows) struct PinnedRowShownTabIconTests {
    static let home = LayoutItem(id: LayoutItemID("itm_tabicon_home"), ref: .builtIn(.home))
    static let page = LayoutItem(id: LayoutItemID("itm_tabicon_page"), ref: .workspace("local:ws-tabicon-page"))
    static let emoji = LayoutItem(id: LayoutItemID("itm_tabicon_emoji"), ref: .workspace("local:ws-tabicon-emoji"))

    /// Each tab's face as `AppServices.sidebarPageFace` gives it: a browser tab's favicon.
    private static func pageFace(_: WorkspaceModel, _ tab: TabModel, _ work: TabModel?) -> SidebarMapping.PageFace? {
        .init(title: (work ?? tab).titleText, favicon: tab.kind == .browser ? PinnedSummaryDensityTests.favicon : nil)
    }

    /// The sidebar row of a workspace with no icon or color of its own whose one tab is a GitHub pull request page.
    static func pageRow() throws -> SidebarWorkspace {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, focusedAt: 1, tabs: [
            TabSnapshot(surface: 1, kind: .browser, title: "Vault H1 H2 fixes", url: "https://github.com/manaflow-ai/cmux/pull/46700"),
        ])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "Vault H1 H2 fixes", screens: [screen])]))
        let workspace = try #require(store.workspaces.first)
        return SidebarMapping.shared.row(workspace, machine: .local, pageFace: Self.pageFace)
    }

    /// Home and the Pinned block with the page workspace and an emoji workspace, as the sidebar document draws them.
    static func list(_ pageRow: SidebarWorkspace) -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        var page = SidebarItemInfo(workspaceRow: pageRow, color: nil)
        page.workspace = WorkspaceID("ws-tabicon-page")
        var emoji = SidebarItemInfo(workspaceRow: SidebarWorkspace(id: WorkspaceID("ws-tabicon-emoji"), title: "Rocket", icon: .emoji("🚀")),
                                    color: nil)
        emoji.workspace = WorkspaceID("ws-tabicon-emoji")
        let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, arrangement: .list, items: [home])
        let pinned = SidebarLayoutDocument.pinnedSection(items: [Self.page, Self.emoji])
        let model = SidebarModel(sections: [
            SidebarSection(kind: .custom(SidebarCustomSection(id: top.id.rawValue)), nodes: []),
            SidebarSection(kind: .custom(SidebarCustomSection(id: pinned.id.rawValue)), nodes: []),
        ])
        let list = SidebarListView(model: model)
        var metrics = SidebarRegionMetrics.standard
        metrics.trailingTrim = SidebarStyle.rowTrailingTrim
        list.blocks = SidebarListBlocks(sections: [top.id.rawValue: top, pinned.id.rawValue: pinned],
                                        infos: [home.id: .fallback(for: home), Self.page.id: page, Self.emoji.id: emoji],
                                        collapsed: [], look: .quiet, metrics: metrics, drawsLines: false, appHeights: [:])
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        for region in list.blockRegions { region.itemViews.values.forEach { $0.needsLayout = true; $0.layoutSubtreeIfNeeded(); $0.layout() } }
        return (list, window)
    }

    /// Runs `body` with `sidebar.pinnedRowLeading` at its default (`ownIcon`).
    static func atDefaultLook(_ body: () throws -> Void) throws {
        try autoreleasepool {
            Motion.reduceMotionOverride = true
            defer { Motion.reduceMotionOverride = nil }
            TunableStore.shared.activate(file: nil)
            TunableStore.shared.register(SidebarTunables.all)
            TunableStore.shared.set(SidebarPinnedRowLeading.tunable.key, nil)
            try #require(SidebarPinnedRowLeading.tunable.value == .ownIcon, "the default look is ownIcon")
            try body()
        }
    }

    /// A pinned workspace whose shown tab is a GitHub page leads as its list row does (Leo 2026-11-23, ask
    /// c-b5d3e0efb6): the page's favicon, no pin, and its title at Home's label x after the icon.
    @Test func aPinnedRowLeadsWithItsShownTabsIconAsItsRowDoes() throws {
        try Self.atDefaultLook {
            let row = try Self.pageRow()
            // The list row keeps the page's favicon, and the pinned row draws the same leading icon.
            #expect(row.icon == .favicon(PinnedSummaryDensityTests.favicon), "the workspace row lost its page's favicon")
            let (list, window) = Self.list(row)
            defer { window.close() }
            let pinned = try HomePinnedRowAlignmentTests.item(list, Self.page.id)
            #expect(pinned.pinSquareFrame == nil, "the pinned row whose shown tab is a GitHub page draws a pin")
            let home = try HomePinnedRowAlignmentTests.item(list, Self.home.id)
            let homeText = list.convert(home.titleFrame, from: home).minX
            let pageText = list.convert(pinned.titleFrame, from: pinned).minX
            #expect(abs(pageText - homeText) <= 0.5, "the pinned page row's title starts at \(pageText), Home's label at \(homeText)")
        }
    }

    /// An icon the user chose leads the pinned row, with no pin before it.
    @Test func aPinnedRowWithItsOwnIconKeepsIt() throws {
        try Self.atDefaultLook {
            let (list, window) = Self.list(try Self.pageRow())
            defer { window.close() }
            let emoji = try HomePinnedRowAlignmentTests.item(list, Self.emoji.id)
            #expect(emoji.pinSquareFrame == nil, "the emoji workspace draws a pin before its own icon")
            #expect(emoji.glyphInkFrame != nil, "the emoji workspace lost its own icon")
        }
    }
}
