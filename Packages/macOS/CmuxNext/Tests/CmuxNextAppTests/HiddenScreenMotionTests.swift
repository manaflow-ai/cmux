import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// The layout steps only the screens it shows. A change that springs on a shown screen (the same
/// panes at another ratio or width: an equalize, a width preset, another client's divider) must
/// start no spring on a hidden screen, and a screen that hides mid-spring must land its own at
/// once: no frame steps a hidden screen, so its panes would stay frozen mid-motion, their content
/// held at the size and edge of a spring that never landed (after a restart a chat pane's content
/// was laid out wider than the pane and pinned to its right edge, its text and composer cut off
/// at the left). A split, a close and a zoom spring on no screen: each is one commit
/// (`PaneLayoutCommitTests`).
@MainActor
@Suite(.closesItsWindows)
struct HiddenScreenMotionTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    static let pair: SplitNode = .split("a1", axis: .horizontal, ratio: 0.5, a: .leaf("a-p1"), b: .leaf("a-p2"))
    /// The pair at another ratio: the same structure, so the change springs on a shown screen.
    static let pairUneven: SplitNode = .split("a1", axis: .horizontal, ratio: 0.3, a: .leaf("a-p1"), b: .leaf("a-p2"))
    static let other: SplitNode = .split("b1", axis: .horizontal, ratio: 0.5, a: .leaf("b-p1"), b: .leaf("b-p2"))
    static let otherUneven: SplitNode = .split("b1", axis: .horizontal, ratio: 0.3, a: .leaf("b-p1"), b: .leaf("b-p2"))

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

    /// A ratio change springs on the shown screen; the same change on a hidden screen puts every
    /// pane at its new place at once.
    @Test func aHiddenScreensLayoutChangeLandsAtOnce() throws {
        let layout = Layout()
        defer { layout.window.closeAfterTest() }
        try #require(layout.root.screenViews["b"]?.isHidden == true, "screen b is shown")
        // Precondition: the same change on the shown screen springs.
        layout.show(a: Self.pairUneven, b: Self.other)
        try #require(layout.isMoving("a"), "a ratio change on the shown screen did not spring")

        layout.show(a: Self.pairUneven, b: Self.otherUneven)
        #expect(!layout.isMoving("b"), "a hidden screen's ratio change started a spring no frame steps")
        let frames = try #require(layout.root.screenViews["b"]?.paneFrames)
        #expect(frames.count == 2 && frames.values.allSatisfy { $0.rect == $0.targetRect }, "\(frames)")
        // The frames it landed at are the new ratio's: the left pane is the narrow one.
        let left = try #require(frames["b-p1"]?.rect.width), right = try #require(frames["b-p2"]?.rect.width)
        #expect(left > 1 && left < right - 100, "the hidden screen did not take the new ratio: \(frames)")
    }

    /// A screen that hides while a ratio change still springs on it lands that spring in the turn
    /// that hides it: nothing of it is on a spring, and no host holds its content.
    @Test func hidingAScreenMidSpringSettlesIt() throws {
        let layout = Layout()
        defer { layout.window.closeAfterTest() }
        layout.show(a: Self.pairUneven, b: Self.other)
        layout.root.advanceFrame(1.0 / 120)
        try #require(layout.isMoving("a"), "the ratio change on the shown screen did not spring")

        // The switch hides screen a in its own turn, with its panes still on their way.
        layout.model.selectScreen("b")
        layout.root.syncWithModel()
        try #require(layout.root.screenViews["a"]?.isHidden == true, "screen a did not hide")
        #expect(!layout.isMoving("a"), "a screen that hid mid-spring stays frozen mid-motion")
        for pane in ["a-p1", "a-p2"] as [PaneID] {
            let host = try #require(layout.root.context.hosts[pane])
            let clip = host.content.superview?.bounds ?? .zero
            #expect(host.content.frame == clip, "\(pane) holds its content: \(host.content.frame) in \(clip)")
        }
    }
}
