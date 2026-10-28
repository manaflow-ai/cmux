import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextTabs
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The window root, its titlebar, a workspace's content and empty
/// state, and a pane's strip on a browser's band are framed in `layout()` from pure functions of
/// bounds and metrics, with no Auto Layout solve (Chrome's `BrowserViewLayout::Layout`).
@MainActor
@Suite struct WindowRootFrameLayoutTests {
    private static let bounds = CGRect(x: 0, y: 0, width: 1000, height: 640)

    private func input(side: SidebarSide = .left, sidebarWidth: CGFloat = 240, rail: CGFloat? = nil,
                       titlebar: CGFloat = 0, panel: CGFloat = 0) -> WindowRootLayout.Input {
        let bounds = Self.bounds
        let x = side == .left ? 0 : bounds.width - sidebarWidth
        return WindowRootLayout.Input(bounds: bounds, sidebarFrame: CGRect(x: x, y: 0, width: sidebarWidth, height: bounds.height),
                                      side: side, railInset: rail, gutter: 6, cardTopInset: 6, titlebarHeight: titlebar,
                                      rightPanelWidth: panel, trafficLightInset: 78)
    }

    // MARK: Window root

    @Test func aLeftSidebarPutsTheMainPaneAGutterBesideIt() {
        let frames = WindowRootLayout(input(side: .left))
        #expect(frames.content == CGRect(x: 246, y: 6, width: 748, height: 628))
        #expect(frames.titlebar == CGRect(x: 240, y: 640, width: 760, height: 0), "minimal: no strip")
    }

    @Test func aRightSidebarPutsTheMainPaneAGutterBeforeIt() {
        let frames = WindowRootLayout(input(side: .right))
        #expect(frames.content == CGRect(x: 6, y: 6, width: 748, height: 628))
        #expect(frames.titlebar.minX == 78, "the title stays clear of the traffic lights")
        #expect(frames.titlebar.maxX == 760, "the title ends at the sidebar")
    }

    @Test func aHiddenSidebarLeavesTheGutterAtTheWindowEdge() {
        for side in SidebarSide.allCases {
            let frames = WindowRootLayout(input(side: side, sidebarWidth: 0))
            #expect(frames.content == CGRect(x: 6, y: 6, width: 988, height: 628), "\(side)")
            #expect(frames.titlebar.minX == 78, "\(side): the title yields to the traffic lights")
            #expect(frames.titlebar.maxX == 1000, "\(side)")
        }
    }

    @Test func aSidebarMidSlideMovesTheEdgeWithIt() {
        let frames = WindowRootLayout(input(side: .left, sidebarWidth: 120.5))
        #expect(frames.content.minX == 126.5)
        #expect(frames.content.maxX == 994)
    }

    @Test func theStandardTitlebarSitsAboveTheMainPane() {
        let frames = WindowRootLayout(input(titlebar: 28))
        #expect(frames.titlebar == CGRect(x: 240, y: 612, width: 760, height: 28))
        #expect(frames.content.maxY == 612 - 6, "the card's top inset runs under the titlebar")
        #expect(frames.content.minY == 6)
    }

    @Test func theRightPanelInsetsTheEdgeOppositeTheSidebar() {
        let left = WindowRootLayout(input(side: .left, panel: 200))
        #expect(left.content.maxX == 1000 - 6 - 200)
        #expect(left.titlebar.maxX == 1000, "the title runs over the panel's top row, as before")
        let right = WindowRootLayout(input(side: .right, panel: 200))
        #expect(right.content.minX == 6 + 200)
    }

    @Test func theRailFramesFromTheWindowEdgeNotTheSidebar() {
        // The rail's full sidebar opens over the content: its frame does not move the content.
        let left = WindowRootLayout(input(side: .left, sidebarWidth: 280, rail: 52))
        #expect(left.content.minX == 52 + 6)
        #expect(left.titlebar.minX == 78, "the rail's title still yields to the traffic lights")
        let right = WindowRootLayout(input(side: .right, sidebarWidth: 280, rail: 52))
        #expect(right.content.maxX == 1000 - 52 - 6)
        #expect(right.titlebar.maxX == 1000 - 52)
    }

    @Test func aTinyWindowNeverGivesNegativeSizes() {
        var tiny = input(titlebar: 28)
        tiny.bounds = CGRect(x: 0, y: 0, width: 100, height: 20)
        let frames = WindowRootLayout(tiny)
        #expect(frames.content.width == 0)
        #expect(frames.content.height == 0)
        #expect(frames.titlebar.width == 0)
    }

    @Test func theRootFramesItsChildrenFromTheLayoutFunction() {
        _ = NSApplication.shared
        let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel(), mainWork: MainWorkScheduler(budget: MainFrameBudget())), revealDeadlines: .testing())
        let window = NSWindow(contentRect: Self.bounds, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = root
        for side in [SidebarSide.right, .left] {
            root.sidebarSide = side
            // sync-layout: the test reads the frames the window's pass places.
            root.layoutSubtreeIfNeeded()
            let expected = WindowRootLayout(root.mainPaneLayoutInput)
            #expect(root.contentHost.frame == root.backingAlignedRect(expected.content, options: .alignAllEdgesNearest), "\(side)")
            #expect(root.titlebar.frame == root.backingAlignedRect(expected.titlebar, options: .alignAllEdgesNearest), "\(side)")
            #expect(root.contentHost.translatesAutoresizingMaskIntoConstraints, "\(side): the card is framed, not constrained")
            #expect(root.titlebar.translatesAutoresizingMaskIntoConstraints, "\(side): the titlebar is framed, not constrained")
        }
    }

    // MARK: Titlebar, workspace content, empty state

    @Test func theTitleCentersAndStopsAtTheInset() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 28)
        #expect(TitlebarView.labelFrame(in: bounds, natural: CGSize(width: 100, height: 16), inset: 16)
            == CGRect(x: 150, y: 6, width: 100, height: 16))
        #expect(TitlebarView.labelFrame(in: bounds, natural: CGSize(width: 900, height: 16), inset: 16)
            == CGRect(x: 16, y: 6, width: 368, height: 16), "a long title truncates inside the insets")
    }

    @Test func theWorkspaceBarTakesItsHeightOnlyWhileShown() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let shown = WorkspaceContentView.Frames(bounds: bounds, barHeight: 30)
        #expect(shown.layout == CGRect(x: 0, y: 0, width: 800, height: 570))
        #expect(shown.bar == CGRect(x: 0, y: 570, width: 800, height: 30))
        #expect(shown.empty == CGRect(x: 0, y: 0, width: 800, height: 600))
        let hidden = WorkspaceContentView.Frames(bounds: bounds, barHeight: 0)
        #expect(hidden.layout == CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    @Test func theEmptyStateCentersTitleAndFailureAsOneGroup() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let title = EmptyWorkspaceView.Frames(in: bounds, title: CGSize(width: 200, height: 24), detail: nil, spacing: 12, inset: 24)
        #expect(title.title == CGRect(x: 300, y: 288, width: 200, height: 24))
        #expect(title.detail == nil)
        let both = EmptyWorkspaceView.Frames(in: bounds, title: CGSize(width: 200, height: 24),
                                             detail: CGSize(width: 400, height: 36), spacing: 12, inset: 24)
        #expect(both.title == CGRect(x: 300, y: 264, width: 200, height: 24))
        #expect(both.detail == CGRect(x: 200, y: 300, width: 400, height: 36))
        let narrow = EmptyWorkspaceView.Frames(in: CGRect(x: 0, y: 0, width: 100, height: 100), title: CGSize(width: 200, height: 24),
                                               detail: nil, spacing: 12, inset: 24)
        #expect(narrow.title.width == 52, "the title stays inside the side insets")
    }

    @Test func theEmptyStateIsFramedByItsWorkspace() {
        let content = WorkspaceContentView(layoutView: NSView(), bar: TabStripView.testing(model: TabStripModel()))
        content.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        let empty = EmptyWorkspaceView(onNew: nil)
        content.showEmpty(empty)
        #expect(empty.frame == content.bounds, "shown at the workspace's size at once")
        #expect(empty.translatesAutoresizingMaskIntoConstraints, "framed, not constrained")
        content.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        // sync-layout: the test reads the frame the window's pass would place.
        content.layoutSubtreeIfNeeded()
        #expect(empty.frame == content.bounds)
    }

    // MARK: Pane strip on a browser's band

    @Test func theBandStripGivesTheToolbarItsWidth() {
        let band = CGRect(x: 0, y: 40, width: 600, height: 30)
        let frames = PaneContentView.bandFrames(band: band, width: 600, tools: 28)
        #expect(frames.strip == CGRect(x: 0, y: 40, width: 572, height: 30))
        #expect(frames.tools == CGRect(x: 572, y: 40, width: 28, height: 30))
        let none = PaneContentView.bandFrames(band: band, width: 600, tools: 0)
        #expect(none.strip.width == 600, "no toolbar: the strip spans the pane")
        #expect(none.tools.width == 0)
    }
}
