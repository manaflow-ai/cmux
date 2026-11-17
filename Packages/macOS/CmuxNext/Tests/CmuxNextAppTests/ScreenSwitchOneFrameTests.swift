import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-11-10: "we should remove changing screen animation". A change of screen (the screen bar, a key, the
/// CLI, a restore, a focus that lands on another screen) is complete in the turn that applies it: the new screen
/// fills the root at alpha 1 and the old one is hidden, with pane animations on. Before, the new screen slid in from
/// 18 % of the width with its alpha on a spring, and the old one hid only when its fade ended some frames later.
/// What the end of that fade did for the old screen (its pane springs land, its resize drag ends) happens in the
/// same turn now. Every test here is the clock: no display link ticks.
@MainActor
@Suite(.closesItsWindows)
struct ScreenSwitchOneFrameTests {
    final class Follower: NSView, PaneResizeGestureFollowing {
        var heard: [Bool] = []
        func paneResizeGestureDidChange(active: Bool) { heard.append(active) }
    }

    final class Panes: LayoutPaneContentProvider {
        let follower = Follower()
        func makeContentView(for pane: PaneID) -> NSView { pane == "a-p2" ? follower : NSView() }
    }

    static let pair: SplitNode = .split("a1", axis: .horizontal, ratio: 0.5, a: .leaf("a-p1"), b: .leaf("a-p2"))
    static let pairSplit: SplitNode = .split("a1", axis: .horizontal, ratio: 0.5, a: .leaf("a-p1"),
                                             b: .split("a2", axis: .horizontal, ratio: 0.5, a: .leaf("a-p2"), b: .leaf("a-p3")))

    static func columns(_ count: Int, prefix: String) -> ScreenLayout {
        .columns((1...count).map {
            LayoutColumn(id: ColumnID("\(prefix)c\($0)"), width: 0.45, root: .leaf(PaneID("\(prefix)p\($0)")))
        })
    }

    /// Screen "a" (two panes) shown, screen "b" hidden, pane animations on, in a window.
    final class Layout {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init(a: ScreenLayout = .splits(ScreenSwitchOneFrameTests.pair), b: ScreenLayout = .splits(.leaf("b-p1")),
             active: ScreenID = "a", focused: PaneID = "a-p1") {
            model = LayoutModel(screens: [LayoutScreen(id: "a", name: "a", layout: a), LayoutScreen(id: "b", name: "b", layout: b)],
                                activeScreenID: active, focusedPane: focused)
            model.splitSizingOverride = .even
            root = LayoutRootView(model: model, contentProvider: provider)
            // Motion allowed and pane layout animated (`LayoutContext.animatesPaneLayout`), whatever the host's settings.
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
        }

        func view(_ screen: ScreenID) throws -> ScreenContentView { try #require(root.screenViews[screen]) }

        func select(_ screen: ScreenID) {
            model.selectScreen(screen)
            root.syncWithModel()
        }
    }

    @Test func aScreenSwitchShowsTheNewScreenAtRestInItsOwnTurn() throws {
        let layout = Layout()
        defer { layout.window.closeAfterTest() }
        let incoming = try layout.view("b"), outgoing = try layout.view("a")
        try #require(incoming.isHidden && !outgoing.isHidden, "screen a is not the one shown")
        try #require(layout.root.context.animatesPaneLayout, "pane animations are off: the switch would not have slid")

        layout.select("b")
        #expect(!incoming.isHidden, "the new screen shows")
        #expect(incoming.frame == layout.root.bounds, "at the root's bounds, not sliding in (\(incoming.frame))")
        #expect(incoming.alphaValue == 1, "at full alpha, not fading in (\(incoming.alphaValue))")
        #expect(outgoing.isHidden, "and the old screen is hidden in the same turn")
    }

    /// Nothing is left to animate after the turn: the switch asks for no display frame and the layout is still.
    @Test func aScreenSwitchAsksForNoFrames() throws {
        let layout = Layout(a: .splits(.leaf("a-p1")))
        defer { layout.window.closeAfterTest() }
        let asked = layout.root.driver.startRequests

        layout.select("b")
        #expect(layout.root.driver.startRequests == asked, "the switch asked for display frames")
        #expect(!layout.root.isInLayoutMotion, "the switch put the layout in motion")
        #expect(!layout.root.advanceFrame(1.0 / 120), "a frame after the switch still had something to move")
    }

    /// A layout pass of the root right after the switch (the window resized, the sidebar moved) keeps the new screen
    /// filling the root and the old one hidden.
    @Test func aLayoutPassAfterAScreenSwitchKeepsTheNewScreenFillingTheRoot() throws {
        let layout = Layout()
        defer { layout.window.closeAfterTest() }
        let incoming = try layout.view("b"), outgoing = try layout.view("a")

        layout.select("b")
        layout.window.setContentSize(NSSize(width: 1000, height: 700))
        layout.root.needsLayout = true
        layout.root.layoutSubtreeIfNeeded()
        #expect(layout.root.bounds.size == NSSize(width: 1000, height: 700), "the root did not take the window's new size")
        #expect(incoming.frame == layout.root.bounds, "the new screen fills the resized root (\(incoming.frame))")
        #expect(incoming.alphaValue == 1 && !incoming.isHidden)
        #expect(outgoing.isHidden, "the old screen stays hidden")
        #expect(outgoing.frame.size == layout.root.bounds.size, "a hidden screen keeps the root's size (\(outgoing.frame.size))")
    }

    /// No frame steps a hidden screen (Leo 2026-10-21: panes frozen mid-motion, their content held wider than the
    /// pane). The old screen's pane springs land in the turn that hides it.
    @Test func aScreenHiddenByASwitchMidSpringSettlesInThatTurn() throws {
        let layout = Layout()
        defer { layout.window.closeAfterTest() }
        let outgoing = try layout.view("a")
        layout.model.apply(screens: [LayoutScreen(id: "a", name: "a", layout: .splits(Self.pairSplit)),
                                     LayoutScreen(id: "b", name: "b", layout: .splits(.leaf("b-p1")))])
        layout.root.syncWithModel()
        _ = layout.root.advanceFrame(1.0 / 120)
        try #require(outgoing.hasMotion, "the split on the shown screen did not spring")

        layout.select("b")
        #expect(outgoing.isHidden, "the old screen did not hide in the switch's turn")
        #expect(!outgoing.hasMotion, "a screen that hid mid-spring stays frozen mid-motion")
        #expect(outgoing.paneFrames.count == 3 && outgoing.paneFrames.values.allSatisfy { $0.rect == $0.targetRect })
        for pane in ["a-p1", "a-p2", "a-p3"] as [PaneID] {
            let host = try #require(layout.root.context.hosts[pane])
            #expect(!host.isOnLayoutSpring, "\(pane.rawValue) still holds its content on a spring")
            let clip = host.content.superview?.bounds ?? .zero
            #expect(host.content.frame == clip, "\(pane.rawValue) holds its content: \(host.content.frame) in \(clip)")
        }
    }

    /// Nor does a frame land a resize drag on a hidden screen: the pages that follow the drag hear its end in the turn
    /// that hides their screen, and lay out at their pane's size.
    @Test func aScreenSwitchEndsTheOldScreensResizeDragInThatTurn() throws {
        let layout = Layout()
        defer { layout.window.closeAfterTest() }
        let outgoing = try layout.view("a")
        outgoing.resizeGestureMoved()
        try #require(layout.provider.follower.heard == [true], "the pane content did not hear the drag begin")

        layout.select("b")
        #expect(outgoing.isHidden)
        #expect(layout.provider.follower.heard == [true, false], "the drag did not end with the hide: \(layout.provider.follower.heard)")
        #expect(outgoing.resizeGesture == .idle)
    }

    /// A screen shows at rest: what the switch changes in it while it is hidden (focus goes to its first pane, the
    /// strip camera reveals that pane's column) lands in the same turn, not on a camera spring after the screen shows.
    @Test func aScreenShownByASwitchHasItsCameraAtRest() throws {
        let layout = Layout(b: Self.columns(4, prefix: "b-"), active: "b", focused: "b-p4")
        defer { layout.window.closeAfterTest() }
        let strip = try layout.view("b")
        try #require(strip.scroll.value > 1, "the strip did not scroll to its last column (\(strip.scroll.value))")
        layout.select("a")
        // Whatever the switch away left to run has run: the strip's screen is hidden and still.
        for _ in 0..<240 where layout.root.advanceFrame(1.0 / 120) {}
        try #require(strip.isHidden && !strip.hasMotion, "the strip's screen did not hide at rest")
        let asked = layout.root.driver.startRequests

        // Back: focus goes to the strip's first pane, a camera move of more than a column.
        layout.select("b")
        try #require(layout.model.focusedPane == "b-p1")
        #expect(!strip.isHidden && strip.frame == layout.root.bounds && strip.alphaValue == 1)
        #expect(strip.scroll.value == strip.scroll.target, "the camera is on a spring after the screen shows (\(strip.scroll.value) -> \(strip.scroll.target))")
        #expect(strip.scroll.value < 1, "the camera shows the first column (\(strip.scroll.value))")
        #expect(!strip.hasMotion)
        #expect(layout.root.driver.startRequests == asked, "the switch asked for display frames")
    }
}
