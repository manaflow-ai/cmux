import AppKit
import CmuxNextBridge
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// Second review of #32635 (FIX FIRST at 593effbd3d7, comment 6591798082):
/// - On a 2x screen a moving frame's edges round to half points, so the last frames of a key spring are 0.5 pt from
///   rest. The held content picked its edge again on those frames, took the other edge, and kept it through the landing:
///   the content jumped by the press step, then back at the reflow. The edge is chosen once, when the hold starts.
/// - A split, a close or a zoom during a key spring: a pane already on the key spring does not start a new spring, so it
///   kept the key hold (its pre-press size) through the structural spring. A structural change ends the key hold of every
///   pane of the screen; they follow that spring live, as any split does.
@MainActor
@Suite(.closesItsWindows)
struct KeyboardResizeHoldTakeoverTests {
    typealias Panes = KeyboardResizeContentHoldTests.Panes

    /// A window that reports a 2x backing store whatever display it is on: frames round to half points.
    final class TwoXWindow: NSWindow {
        override var backingScaleFactor: CGFloat { 2 }
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
            window = TwoXWindow(contentRect: NSRect(x: 0, y: 0, width: 1201, height: 801), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            root.context.afterCommit = { [unowned self] in self.afterCommit.append($0) }
        }

        var screen: ScreenContentView { get throws { try #require(root.screenViews["s"]) } }
    }

    @Test(arguments: [LayoutDirection.left, .right])
    func onA2xScreenTheHeldContentKeepsItsEdgeThroughTheLanding(direction: LayoutDirection) throws {
        let rig = Rig()
        defer { rig.window.closeAfterTest() }
        #expect(try rig.screen.scale == 2)
        let content = try #require(rig.provider.views["p2"])
        #expect(PaneResize.press("p2", direction, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        // p2 is right of the divider: its right edge stays, so its held content rides that edge in every frame.
        func trailingInWindow() -> CGFloat { content.convert(content.bounds, to: nil).maxX }
        let start = trailingInWindow()
        var frames = 0
        while frames < 240, rig.root.advanceFrame(1.0 / 120) {
            rig.root.layoutSubtreeIfNeeded()
            #expect(abs(trailingInWindow() - start) < 0.01, "frame \(frames): the held content left its edge (\(trailingInWindow()) vs \(start))")
            frames += 1
        }
        rig.root.layoutSubtreeIfNeeded()
        #expect(abs(trailingInWindow() - start) < 0.01, "the landing frame moved the held content to the other edge (\(trailingInWindow()) vs \(start))")
    }

    @Test func aSplitDuringAKeySpringResizesThePanesThatWereMovingLive() throws {
        let rig = Rig()
        defer { rig.window.closeAfterTest() }
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        _ = rig.root.advanceFrame(1.0 / 120)
        _ = rig.root.advanceFrame(1.0 / 120)
        // A split of p2 while the key spring runs: p1 and p2 were on the key spring and keep moving on the split's.
        let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 0.45, a: .leaf("p1"),
                                                                     b: .split("y", axis: .vertical, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3"))))]
        rig.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))])
        rig.root.syncWithModel()
        var frames = 0
        while frames < 240, rig.root.advanceFrame(1.0 / 120) {
            rig.root.layoutSubtreeIfNeeded()
            for pane in ["p1", "p2"] as [PaneID] {
                let content = try #require(rig.provider.views[pane])
                #expect(content.frame.size == content.superview?.bounds.size,
                        "frame \(frames): \(pane) kept the key hold (\(content.frame.size)) on the split's spring (\(String(describing: content.superview?.bounds.size)))")
            }
            frames += 1
        }
        #expect(frames > 0, "the split did not spring")
    }
}
