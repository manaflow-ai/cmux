import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// Leo 2026-10-21: after a restart the chat pane's content was laid out wider than the pane and
/// pinned to its right edge, its text and composer cut off at the left. The layout steps only the
/// screens it shows, but a hidden screen's layout change (a restore, a daemon echo) still started
/// pane springs there, and a screen that hid mid-spring kept its own: its panes stayed frozen
/// mid-motion, their content held at the size and edge of a spring that never landed.
@MainActor
@Suite(.closesItsWindows)
struct HiddenScreenMotionTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    static let pair: SplitNode = .split("a1", axis: .horizontal, ratio: 0.5, a: .leaf("a-p1"), b: .leaf("a-p2"))
    static let pairSplit: SplitNode = .split("a1", axis: .horizontal, ratio: 0.5, a: .leaf("a-p1"),
                                             b: .split("a2", axis: .horizontal, ratio: 0.5, a: .leaf("a-p2"), b: .leaf("a-p3")))
    static let other: SplitNode = .split("b1", axis: .horizontal, ratio: 0.5, a: .leaf("b-p1"), b: .leaf("b-p2"))
    static let otherSplit: SplitNode = .split("b1", axis: .horizontal, ratio: 0.5, a: .leaf("b-p1"),
                                              b: .split("b2", axis: .horizontal, ratio: 0.5, a: .leaf("b-p2"), b: .leaf("b-p3")))

    /// Screen "a" shown, screen "b" hidden, in a window; the test is the clock.
    final class Layout {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init() {
            model = LayoutModel(screens: [LayoutScreen(id: "a", name: "a", layout: .splits(HiddenScreenMotionTests.pair)),
                                          LayoutScreen(id: "b", name: "b", layout: .splits(HiddenScreenMotionTests.other))],
                                activeScreenID: "a", focusedPane: "a-p1")
            model.splitSizingOverride = .even
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
        }

        func show(a: SplitNode, b: SplitNode) {
            model.apply(screens: [LayoutScreen(id: "a", name: "a", layout: .splits(a)),
                                  LayoutScreen(id: "b", name: "b", layout: .splits(b))])
            root.syncWithModel()
        }

        /// Whether any of `screen`'s panes is off its rest or its host holds content on a spring.
        func isMoving(_ screen: ScreenID) -> Bool {
            guard let view = root.screenViews[screen] else { return false }
            let springing = view.paneFrames.keys.contains { root.context.hosts[$0]?.isOnLayoutSpring == true }
            return view.hasMotion || springing
        }
    }

    @Test func aHiddenScreensLayoutChangeLandsAtOnce() throws {
        let layout = Layout()
        defer { layout.window.closeAfterTest() }
        try #require(layout.root.screenViews["b"]?.isHidden == true, "screen b is shown")
        // Precondition: the same change on the shown screen springs.
        layout.show(a: Self.pairSplit, b: Self.other)
        try #require(layout.isMoving("a"), "a split on the shown screen did not spring")

        layout.show(a: Self.pairSplit, b: Self.otherSplit)
        #expect(!layout.isMoving("b"), "a hidden screen's split started a spring no frame steps")
        let frames = try #require(layout.root.screenViews["b"]?.paneFrames)
        #expect(frames.count == 3 && frames.values.allSatisfy { $0.rect == $0.targetRect }, "\(frames)")
    }

    @Test func hidingAScreenMidSpringSettlesIt() throws {
        let layout = Layout()
        defer { layout.window.closeAfterTest() }
        layout.show(a: Self.pairSplit, b: Self.other)
        layout.root.advanceFrame(1.0 / 120)
        try #require(layout.isMoving("a"), "the split on the shown screen did not spring")

        layout.model.selectScreen("b")
        layout.root.syncWithModel()
        // The switch's fade ends: screen a hides with its split still on its way.
        layout.root.screenFrames["a"]?.snap()
        layout.root.applyScreenFrames()
        try #require(layout.root.screenViews["a"]?.isHidden == true, "screen a did not hide")
        #expect(!layout.isMoving("a"), "a screen that hid mid-spring stays frozen mid-motion")
        for pane in ["a-p1", "a-p2", "a-p3"] as [PaneID] {
            let host = try #require(layout.root.context.hosts[pane])
            let clip = host.content.superview?.bounds ?? .zero
            #expect(host.content.frame == clip, "\(pane) holds its content: \(host.content.frame) in \(clip)")
        }
    }
}
