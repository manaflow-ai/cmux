import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S1: a key resize holds only each pane's content area (`PaneContentAreaView`). The held content
/// keeps its frame and its edge, takes the pane's size once at the release, and does so before it hears that the motion
/// ended (a terminal then sizes its surface from its final frame). A chat that draws its tools in the tab row keeps the
/// whole-view hold (page pixels: stage S5/S6).
@MainActor
@Suite(.serialized, .closesItsWindows)
struct PaneContentAreaHoldTests {
    /// Content that rides the bottom edge (a terminal with its prompt on its last row) and records its frame when it
    /// hears the motion settled.
    final class Settling: NSView, PaneMotionTargeting, PaneMotionSettling {
        var settledFrames: [CGRect] = []
        func paneMotionWillRest(sizeChange: CGSize) -> PaneMotionAnchor { .bottom }
        func paneMotionDidSettle() { settledFrames.append(frame) }
    }

    final class Panes: LayoutPaneContentProvider {
        let reveal: LaunchReveal = {
            let reveal = LaunchReveal()
            reveal.markAllReady()
            return reveal
        }()
        var views: [PaneID: PaneContentView] = [:]
        var contents: [PaneID: Settling] = [:]

        func makeContentView(for pane: PaneID) -> NSView {
            let tabs = (0..<2).map { TabItem(id: TabID("tab\($0)"), title: "python3 /tmp/sigwinch.py --seed 100\($0)") }
            let view = PaneContentView(stripModel: TabStripModel(tabs: tabs, selectedID: tabs[0].id), reveal: reveal)
            let content = Settling()
            view.show(content)
            views[pane] = view
            contents[pane] = content
            return view
        }
    }

    final class Rig {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        var afterCommit: [@MainActor () -> Void] = []

        init() {
            _ = NSApplication.shared
            let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))]
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s", focusedPane: "p2")
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            root.context.afterCommit = { [unowned self] in self.afterCommit.append($0) }
        }

        /// One press of `direction` on p2, the spring to its landing, the landing's after-commit release and one more
        /// layout pass. `frame` runs after each frame's layout pass.
        func press(_ direction: LayoutDirection, frame: (Int) -> Void = { _ in }) throws {
            #expect(PaneResize.press("p2", direction, model: model, view: root))
            var frames = 0
            while frames < 240, root.advanceFrame(1.0 / 120) {
                root.layoutSubtreeIfNeeded()
                frames += 1
                frame(frames)
            }
            try #require(frames > 3, "the press did not spring (\(frames) frames)")
            root.layoutSubtreeIfNeeded()
            let release = afterCommit
            afterCommit.removeAll()
            for work in release { work() }
            root.layoutSubtreeIfNeeded()
        }
    }

    /// The held content keeps its frame in every frame (only the area's bounds origin moves), and at the release it has
    /// its final size before it hears that the motion ended.
    @Test(arguments: [LayoutDirection.left, .right])
    func theHeldContentTakesItsFinalSizeBeforeItHearsTheLanding(_ direction: LayoutDirection) throws {
        let rig = Rig()
        defer { rig.window.closeAfterTest() }
        let view = try #require(rig.provider.views["p2"]), content = try #require(rig.provider.contents["p2"])
        let start = content.frame
        content.settledFrames.removeAll()
        var moved: [String] = []
        try rig.press(direction) { frame in
            if content.frame != start { moved.append("frame \(frame): \(content.frame)") }
            if !view.contentHost.isHolding { moved.append("frame \(frame): the area let go before the landing") }
        }
        #expect(moved.isEmpty, "the held content moved or resized during the spring: \(moved.prefix(4))")
        #expect(!view.contentHost.isHolding && view.contentHost.bounds.origin == .zero, "the hold did not end at the release")
        #expect(content.frame == view.contentHost.bounds, "the content did not take its area's size at the release: \(content.frame)")
        #expect(content.settledFrames == [view.contentHost.bounds],
                "the content heard the landing at \(content.settledFrames), not at its final frame \(view.contentHost.bounds)")
    }

    /// A chat that draws its tools in the tab row: its page draws the row, so the whole view holds (S5/S6 own it).
    @Test func aPageThatSharesTheTabRowHoldsWhole() throws {
        final class RowPage: NSView, PaneTabRowSharing {
            var tabRowToolsWidth: CGFloat? { 80 }
            var tabRowToolsNeed: CGFloat? { 80 }
            var onTabRowToolsChange: (() -> Void)?
            func setTabRow(height: CGFloat, trailingInset: CGFloat) {}
        }
        let reveal = LaunchReveal()
        reveal.markAllReady()
        let tabs = (0..<2).map { TabItem(id: TabID("tab\($0)"), title: "Chat \($0)") }
        let pane = PaneContentView(stripModel: TabStripModel(tabs: tabs, selectedID: tabs[0].id), reveal: reveal)
        pane.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        pane.show(RowPage())
        pane.layoutSubtreeIfNeeded()
        #expect(pane.paneMotionHoldArea == nil, "a page that draws its tools in the tab row held only its area")
        pane.show(NSView())
        pane.needsLayout = true
        pane.layoutSubtreeIfNeeded()
        #expect(pane.paneMotionHoldArea === pane.contentHost, "a plain content did not hold its area only")
    }
}
