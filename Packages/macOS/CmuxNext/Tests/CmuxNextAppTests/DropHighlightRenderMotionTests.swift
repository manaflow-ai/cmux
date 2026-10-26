import AppKit
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// The tab-drop highlight on the render server (chrome-parity p03-rendering-032, `motion.renderServer`
/// on): a drag across three zones is three `RenderSpring` retargets of the outline ring, one per event
/// that moves the target, and the display frames never step the highlight. With the switch off it moves
/// and steps as before.
@MainActor
@Suite(.serialized)
struct DropHighlightRenderMotionTests {
    /// Two panes side by side in a 1200 x 700 window; the drag goes over `p2`.
    final class Drag {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(
            .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))))], activeScreenID: "s", focusedPane: "p1")
        let provider = ColumnCloseScrollMotionTests.Panes()
        let root: LayoutRootView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)

        init(renderServer: Bool) {
            root = LayoutRootView(model: model, contentProvider: provider, rendersMotionOnServer: { renderServer })
            root.context.reduceMotionOverride = false
            window.isReleasedWhenClosed = false
            window.contentView = root
            window.orderFrontRegardless()
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
        }

        var highlight: DropHighlightView { root.highlight }

        /// A window point over `p2`: `x` is the fraction across it.
        func over(_ x: CGFloat) throws -> CGPoint {
            let p2 = try #require(root.frame(of: "p2"))
            return root.convert(CGPoint(x: p2.minX + p2.width * x, y: p2.midY), to: nil)
        }

        @discardableResult
        func move(to x: CGFloat) throws -> DropTarget? {
            root.updateTabDrag("t", locationInWindow: try over(x))
        }

        /// A few display frames, as a layout motion elsewhere would run them.
        func frames(_ count: Int = 4) {
            for _ in 0..<count { _ = root.advanceFrame(1.0 / 120) }
        }

        /// The ring's springs a `RenderSpring` added, and the ones that replace each other (`MotionGate.set`).
        var ringSprings: (additive: Int, replacing: Int) {
            let keys = highlight.outline?.ringLayer.animationKeys() ?? []
            let additive = keys.filter { $0.hasPrefix("cmux.renderSpring.") }.count
            let replacing = keys.filter { ["bounds", "position", "cornerRadius"].contains($0) }.count
            return (additive, replacing)
        }

        /// The ring's moves animate here: the window is on a screen and movement is on.
        var animates: Bool { Motion.canAnimate(in: root) && Motion.panes.animatesMovement }
    }

    @Test func registersTheDropHighlightOnTheRoot() {
        #expect(LayoutRootView.renderServerMotions.map(\.kind) == [.dropHighlight])
    }

    @Test func threeZonesAreThreeRetargetsAndNoTicks() throws {
        let drag = Drag(renderServer: true)
        defer { drag.window.orderOut(nil) }
        try #require(drag.highlight.style == .outline, "the default style moves itself")
        #expect(try drag.move(to: 0.05) == .pane("p2", .left))
        #expect(!drag.root.highlightStepsOnFrames)
        // A pointer move inside the zone moves nothing.
        try drag.move(to: 0.07)
        #expect(try drag.move(to: 0.5) == .pane("p2", .center))
        drag.frames()
        #expect(try drag.move(to: 0.95) == .pane("p2", .right))
        drag.frames()
        #expect(drag.highlight.renderServerMoves == 3, "one retarget per zone")
        #expect(drag.highlight.steps == 0, "advanceFrame no longer steps the highlight")
        #expect(!drag.highlight.isMoving)
        #expect(!drag.root.highlightStepsOnFrames)
        let rest = try #require(drag.highlight.outline?.ringFrame)
        let target = drag.highlight.destinationRect
        #expect(abs(rest.minX - target.minX) < 0.01 && abs(rest.minY - target.minY) < 0.01
                    && abs(rest.width - target.width) < 0.01 && abs(rest.height - target.height) < 0.01,
                "the model is at the target from the event's turn: \(rest) vs \(target)")
        if drag.animates {
            #expect(drag.ringSprings.additive > 0)
            #expect(drag.ringSprings.replacing == 0, "a replacing spring would pin the additive ones")
        }
        drag.root.cancelTabDrag()
        #expect(!drag.highlight.isShowing)
        drag.frames()
        #expect(drag.highlight.steps == 0)
    }

    @Test func offTheHighlightMovesAndStepsAsBefore() throws {
        let drag = Drag(renderServer: false)
        defer { drag.window.orderOut(nil) }
        try #require(drag.highlight.style == .outline)
        try drag.move(to: 0.05)
        try drag.move(to: 0.5)
        try drag.move(to: 0.95)
        #expect(drag.highlight.renderServerMoves == 0)
        #expect(drag.root.highlightStepsOnFrames)
        drag.frames(2)
        #expect(drag.highlight.steps == 2)
        if drag.animates {
            #expect(drag.ringSprings.additive == 0)
            #expect(drag.ringSprings.replacing > 0)
        }
        drag.root.cancelTabDrag()
    }

    @Test func aStyleTheCPUDrawsStillStepsWhileItMoves() throws {
        TunableStore.shared.set(DropOverlayTunables.style.key, .choice(DropOverlayStyle.hairline.rawValue))
        defer { TunableStore.shared.set(DropOverlayTunables.style.key, nil) }
        let drag = Drag(renderServer: true)
        defer { drag.window.orderOut(nil) }
        try drag.move(to: 0.05)
        try drag.move(to: 0.95)
        #expect(drag.highlight.style == .hairline)
        #expect(drag.highlight.renderServerMoves == 0, "the render server takes only a self-driven style")
        #expect(drag.highlight.isMoving)
        #expect(drag.root.highlightStepsOnFrames)
        for _ in 0..<600 where drag.highlight.isMoving { drag.frames(1) }
        #expect(drag.highlight.steps > 0)
        #expect(!drag.highlight.isMoving, "the springs land")
        #expect(!drag.root.highlightStepsOnFrames)
        drag.root.cancelTabDrag()
    }
}
