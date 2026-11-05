import AppKit
import CmuxNextBridge
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// Review of #32635 (FIX FIRST at fcd7cf32995, comment 6590748680):
/// - The held content rides the edge nearer its rest through the whole spring; it must not switch edges in the landing
///   frame (a jump of the whole press step before the release).
/// - The screen's key-resize hold must end with the press's motion on every path: a press that does not spring
///   (Reduce Motion), a motion landed at once (`landMotion`: window out of sight, Reduce Motion turned on), a split
///   that takes over. A flag left set made the next split's new pane or a zoom hold its content (empty or tiny).
@MainActor
@Suite(.closesItsWindows)
struct KeyboardResizeHoldLifetimeTests {
    typealias Panes = KeyboardResizeContentHoldTests.Panes

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
            root.driver.isManual = true
            root.context.afterCommit = { [unowned self] in self.afterCommit.append($0) }
        }

        var screen: ScreenContentView { get throws { try #require(root.screenViews["s"]) } }
    }

    @Test(arguments: [LayoutDirection.left, .right])
    func heldContentKeepsItsEdgeThroughTheLanding(direction: LayoutDirection) throws {
        let rig = Rig()
        defer { rig.window.closeAfterTest() }
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

    @Test func aPressThatDoesNotSpringLeavesNoHold() throws {
        let rig = Rig()
        defer { rig.window.closeAfterTest() }
        rig.root.context.reduceMotionOverride = true
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        _ = rig.root.advanceFrame(1.0 / 120)
        #expect(try rig.screen.holdsContentForKeyResize == false, "a press with Reduce Motion left the screen holding content")
    }

    @Test func aMotionLandedAtOnceLeavesNoHold() throws {
        let rig = Rig()
        defer { rig.window.closeAfterTest() }
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        _ = rig.root.advanceFrame(1.0 / 120)
        rig.root.landMotion()
        #expect(try rig.screen.holdsContentForKeyResize == false, "landMotion left the screen holding content")
    }

    @Test func aSplitDuringAKeySpringDoesNotHoldItsNewPane() throws {
        let rig = Rig()
        defer { rig.window.closeAfterTest() }
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        _ = rig.root.advanceFrame(1.0 / 120)
        // A split of p2 while the key spring runs (a structural change): the new pane p3 springs in with live content.
        let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 0.45, a: .leaf("p1"),
                                                                     b: .split("y", axis: .vertical, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3"))))]
        rig.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))])
        rig.root.syncWithModel()
        var frames = 0
        while frames < 240, rig.root.advanceFrame(1.0 / 120) {
            rig.root.layoutSubtreeIfNeeded()
            frames += 1
        }
        rig.root.layoutSubtreeIfNeeded()
        let p3 = try #require(rig.provider.views["p3"])
        #expect(p3.frame.size == p3.superview?.bounds.size, "the split's new pane is held at \(p3.frame.size) after its spring landed, before any release")
    }
}
