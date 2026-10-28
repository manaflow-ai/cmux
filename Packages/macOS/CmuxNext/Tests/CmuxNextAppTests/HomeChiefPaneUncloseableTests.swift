import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTabs
import Testing

/// The Home Chief pane (the pinned left chat dock, `pinned-dock-v1`) cannot close (Lawrence 2026-10-20:
/// "make it impossible to close home chief left hand side"). It shows no tab bar while it holds only
/// Home (Lawrence 2026-10-23, HomeChiefPaneHasNoTabBarTests), and it takes tabs dragged into it (Leo
/// 2026-10-21), whose strip then shows. plans/cmux-next/home-chief-pane.md. The daemon keeps the
/// pinned tab (cmux-tui `pinned_columns_tests.rs`); these cover what the app shows and asks.
@MainActor
struct HomeChiefPaneUncloseableTests {
    static let home = DockColumn(edge: .left, mode: .docked, role: .agentChat, isPinned: true)

    /// No tab bar over Home's one tab; a tab dragged in brings the strip back so it stays reachable.
    /// An unpinned dock keeps its bar.
    @Test func aPinnedDockHoldingOnlyHomeShowsNoTabBar() {
        #expect(Self.home.hidesTabBar(shownTabs: 1))
        #expect(Self.home.hidesTabBar(shownTabs: 0))
        #expect(!Self.home.hidesTabBar(shownTabs: 2), "a dragged-in tab stays reachable")
        var open = Self.home
        open.allowsTabs = true
        #expect(open.hidesTabBar(shownTabs: 1), "Home's dock takes tabs and still shows no bar alone")
        #expect(!DockColumn(edge: .left, role: .agentChat).hidesTabBar(shownTabs: 1), "an unpinned chat dock keeps its bar")
        #expect(!DockColumn(edge: .right).hidesTabBar(shownTabs: 1))
    }

    /// Cmd-W with focus in Home does nothing, with no notice: Home's tab is the only one there.
    @Test func cmdWOnHomeAloneIsIgnoredSilently() {
        var home = TabItem(id: "home", title: "Home")
        home.isClosable = false
        let alone = TabStripModel(tabs: [home], selectedID: "home")
        #expect(alone.keyboardClose("home") == .ignore)
        #expect(alone.keyboardClose("home", closesPinned: true) == .ignore)
        // A pinned (not Home) tab alone keeps the old notice.
        var pinned = TabItem(id: "p", title: "p")
        pinned.isPinned = true
        #expect(TabStripModel(tabs: [pinned], selectedID: "p").keyboardClose("p") == .keep)
    }

    /// Close Other Tabs / to the Left / to the Right never list a tab that cannot close.
    @Test func bulkTabClosesSkipATabThatCannotClose() {
        var home = TabItem(id: "home", title: "Home")
        home.isClosable = false
        let strip = TabStripModel(tabs: [home, TabItem(id: "a", title: "a"), TabItem(id: "b", title: "b")], selectedID: "a")
        #expect(strip.closedByCloseOthers(keeping: "a") == ["b"])
        #expect(strip.closedByCloseToLeft(of: "b") == ["a"])
        #expect(strip.closedByCloseToRight(of: "home") == ["a", "b"])
        #expect(!strip.closedByCloseToLeft(of: "a").contains("home"))
    }

    /// A dragged tab finds no drop target over Home (center or edge): nothing joins or splits the
    /// pinned dock, and no highlight promises it. The strip next to it still takes the drop.
    @Test func tabDropsFindNoTargetOverAPinnedDock() throws {
        let screen = Screen(dock: Self.home)
        let dock = try #require(screen.view.geometry.panes["dock"])
        for point in [CGPoint(x: dock.midX, y: dock.midY), CGPoint(x: dock.maxX - 4, y: dock.midY),
                      CGPoint(x: dock.midX, y: dock.maxY - 6)] {
            #expect(screen.view.dropTarget(at: point) == nil, "Home took a drop at \(point)")
        }
        let strip = try #require(screen.stripCenter())
        guard case .pane("p1", _)? = screen.view.dropTarget(at: strip)?.target else {
            Issue.record("the strip pane lost its drop target")
            return
        }
        var open = Self.home
        open.allowsTabs = true
        let allowed = Screen(dock: open)
        guard case .pane("dock", _)? = allowed.view.dropTarget(at: CGPoint(x: dock.midX, y: dock.midY))?.target else {
            Issue.record("a pinned dock with allow_tabs refused a drop")
            return
        }
    }

    /// Home's dock as the app makes it (`allow_tabs` on) takes a dragged tab, and every zone over it
    /// joins the tab to the dock: the pinned dock never splits, so no edge previews a split there.
    @Test func homesDockJoinsADroppedTabAndNeverSplits() throws {
        var open = Self.home
        open.allowsTabs = true
        let screen = Screen(dock: open)
        let dock = try #require(screen.view.geometry.panes["dock"])
        for point in [CGPoint(x: dock.midX, y: dock.midY), CGPoint(x: dock.maxX - 4, y: dock.midY),
                      CGPoint(x: dock.minX + 4, y: dock.midY), CGPoint(x: dock.midX, y: dock.maxY - 6)] {
            let target = screen.view.dropTarget(at: point)?.target
            guard case .pane("dock", .center)? = target else {
                Issue.record("Home's dock did not join a drop at \(point): \(String(describing: target))")
                continue
            }
        }
    }

    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    /// A Home screen: the dock on the left, one strip column.
    final class Screen {
        let panes = Panes()
        let context: LayoutViewContext
        let view: ScreenContentView
        let window: NSWindow

        init(dock: DockColumn) {
            let layout = ScreenLayout.columns([
                LayoutColumn(id: "home", width: 0.4, root: .leaf("dock"), dock: dock),
                LayoutColumn(id: "c1", width: 1, root: .leaf("p1")),
            ])
            let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout)], activeScreenID: "s", focusedPane: "p1")
            context = LayoutViewContext(model: model, provider: panes)
            context.livePanes = ["dock", "p1"]
            view = ScreenContentView(screenID: "s", layout: layout, context: context)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = view
            view.reconcile(animated: false)
        }

        /// The strip pane's center in view coordinates.
        func stripCenter() -> CGPoint? {
            guard let cell = view.geometry.panes["p1"] else { return nil }
            let shown = cell.offsetBy(dx: view.geometry.viewShift(offset: view.scroll.value), dy: 0)
            return CGPoint(x: shown.midX, y: shown.midY)
        }
    }
}
