import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSidebar
import Testing

/// Tab bars at the bottom show no title strip above the panes (user, 2026-10-28: "when tabbar is
/// at bottom we shouldnt show this at top (we need to conserve more space)"). The panes reach the
/// window's top edge; the traffic lights stay clear of them: on the sidebar's header when the
/// sidebar shows on the left, otherwise in a row the main pane starts below. Rects are in window
/// coordinates (y up).
@MainActor @Suite(.serialized) struct BottomTabsTitleStripTests {
    /// Runs `body` with `tabs.barPosition` at `position`, the minimal title bar (the default) and the
    /// sidebar on `side`; restores the process-wide settings after.
    func with<T>(tabs position: TabBarPosition, side: SidebarSide = .left, _ body: () throws -> T) rethrows -> T {
        let design = DesignSettings.shared
        let before = (design.tabBarPosition, design.titlebar, design.sidebarSide)
        design.tabBarPosition = position
        design.titlebar = .minimal
        design.sidebarSide = side
        defer { (design.tabBarPosition, design.titlebar, design.sidebarSide) = before }
        return try body()
    }

    func root(sidebarHidden: Bool) -> (NSWindow, WindowRootView) {
        _ = NSApplication.shared
        let model = SidebarModel()
        if sidebarHidden { model.presentation = .hidden }
        let root = WindowRootView(sidebar: SidebarContainerView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        if sidebarHidden {
            root.sidebar.isHidden = true
            root.sidebarHidden = true
        }
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        return (window, root)
    }

    func card(_ root: WindowRootView) -> CGRect { root.contentHost.convert(root.contentHost.bounds, to: nil) }

    /// The screenshot's case: the sidebar on the left holds the traffic lights, and the panes
    /// start right at the top, with no workspace-name strip.
    @Test func withTheSidebarShownThePanesReachTheTop() throws {
        try with(tabs: .bottom) {
            let (window, root) = root(sidebarHidden: false)
            defer { window.close() }
            let lights = try #require(WindowTitlebar.trafficLightsFrame(in: window))
            let top = window.contentView!.bounds.maxY - card(root).maxY
            #expect(root.titlebar.isHidden, "no title strip with the workspace name")
            #expect(top <= Metrics.mainPaneGutter, "the panes start \(top) pt below the window top")
            #expect(lights.maxX <= root.sidebar.convert(root.sidebar.bounds, to: nil).maxX, "the lights sit on the sidebar")
        }
    }

    /// Nothing holds the lights (sidebar hidden, or on the right): the main pane starts below
    /// their row, so they never cover a pane's content.
    @Test(arguments: [(SidebarSide.left, true), (SidebarSide.right, false), (SidebarSide.right, true)])
    func withoutTheSidebarUnderThemTheLightsClearThePanes(side: SidebarSide, hidden: Bool) throws {
        try with(tabs: .bottom, side: side) {
            let (window, root) = root(sidebarHidden: hidden)
            defer { window.close() }
            let lights = try #require(WindowTitlebar.trafficLightsFrame(in: window))
            #expect(root.titlebar.isHidden, "no title strip with the workspace name")
            #expect(card(root).maxY <= lights.minY, "the card's top \(card(root).maxY) is under the lights' bottom \(lights.minY)")
        }
    }

    /// Tab bars on top are unchanged: with the sidebar hidden the top-left strip starts after the
    /// lights, and the card keeps its small top inset.
    @Test func topTabBarsKeepTheirTopRow() throws {
        try with(tabs: .top) {
            let (window, root) = root(sidebarHidden: true)
            defer { window.close() }
            let top = window.contentView!.bounds.maxY - card(root).maxY
            #expect(top <= Metrics.mainPaneGutter)
        }
    }
}
