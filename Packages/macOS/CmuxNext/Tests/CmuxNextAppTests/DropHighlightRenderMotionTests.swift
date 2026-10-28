import AppKit
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import QuartzCore
import CmuxNextWakeups
import Testing

/// The tab-drop highlight on the render server (`motion.renderServer`
/// on): a drag across three zones is three `RenderSpring` retargets of the outline ring, one per event
/// that moves the target, and the display frames never step the highlight. With the switch off it moves
/// and steps as before.
///
/// The spring checks read the ring layer's animations, so the window is real and ordered in, and a host
/// where nothing animates (no screen, a sleeping display, movement off) fails the tests (`requireAnimates`).
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
            root = LayoutRootView(model: model, contentProvider: provider, rendersMotionOnServer: { renderServer }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            root.context.reduceMotionOverride = false
            window.isReleasedWhenClosed = false
            window.contentView = root
            window.orderFrontRegardless()
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
        }

        var highlight: DropHighlightView { root.highlight }

        /// Pins Reduce Motion off and requires the ring's springs to run here: the window draws frames
        /// and the panes gate animates movement. A host where nothing animates fails the test; it does
        /// not pass with the spring checks skipped.
        func requireAnimates() throws {
            Motion.reduceMotionOverride = false
            try #require(Motion.canAnimate(in: root), "the window is on no screen or its display sleeps: nothing animates")
            try #require(Motion.panes.animatesMovement, "panes movement is off in this host's settings")
        }

        func close() {
            Motion.reduceMotionOverride = nil
            window.orderOut(nil)
        }

        /// A window point over `p2`: `x` is the fraction across it.
        func over(_ x: CGFloat) throws -> CGPoint {
            let p2 = try #require(root.frame(of: "p2"))
            return root.convert(CGPoint(x: p2.minX + p2.width * x, y: p2.midY), to: nil)
        }

        @discardableResult
        func move(to x: CGFloat) throws -> DropTarget? {
            root.updateTabDrag("t", locationInWindow: try over(x))
        }

        /// Moves to `x`: the target, and the key path of each `RenderSpring` spring the move added to
        /// the ring, sorted.
        func retarget(to x: CGFloat) throws -> (target: DropTarget?, added: [String]) {
            let before = ringSpringKeys
            let target = try move(to: x)
            return (target, ringSpringKeys.subtracting(before).map(Self.keyPath(ofSpring:)).sorted())
        }

        /// A few display frames, as a layout motion elsewhere would run them.
        func frames(_ count: Int = 4) {
            for _ in 0..<count { _ = root.advanceFrame(1.0 / 120) }
        }

        static let springPrefix = "cmux.renderSpring."

        /// The keys of the ring's `RenderSpring` springs (`cmux.renderSpring.<serial>.<keyPath>`).
        var ringSpringKeys: Set<String> {
            Set((highlight.outline?.ringLayer.animationKeys() ?? []).filter { $0.hasPrefix(Self.springPrefix) })
        }

        /// The ring's springs that replace each other (`MotionGate.set`, keyed by their key path).
        var replacingSprings: Int {
            (highlight.outline?.ringLayer.animationKeys() ?? []).filter { ["bounds", "position", "cornerRadius"].contains($0) }.count
        }

        static func keyPath(ofSpring key: String) -> String {
            let rest = key.dropFirst(springPrefix.count)
            guard let dot = rest.firstIndex(of: ".") else { return String(rest) }
            return String(rest[rest.index(after: dot)...])
        }

        /// The ring's model values: what a move springs.
        struct Ring {
            var size: CGSize
            var position: CGPoint
            var cornerRadius: CGFloat
        }

        var ring: Ring? {
            guard let layer = highlight.outline?.ringLayer else { return nil }
            return Ring(size: layer.bounds.size, position: layer.position, cornerRadius: layer.cornerRadius)
        }

        /// The key paths a move from `old` to `new` springs, sorted: one additive spring each.
        static func movedKeyPaths(from old: Ring, to new: Ring) -> [String] {
            var paths: [String] = []
            if old.size != new.size { paths.append("bounds.size") }
            if old.cornerRadius != new.cornerRadius { paths.append("cornerRadius") }
            if old.position != new.position { paths.append("position") }
            return paths
        }
    }

    @Test func registersTheDropHighlightOnTheRoot() {
        #expect(LayoutRootView.renderServerMotions.map(\.kind) == [.dropHighlight])
    }

    @Test func threeZonesAreThreeRetargetsAndNoTicks() throws {
        let drag = Drag(renderServer: true)
        defer { drag.close() }
        try drag.requireAnimates()
        try #require(drag.highlight.style == .outline, "the default style moves itself")
        let starts = drag.root.driver.startRequests

        let left = try drag.retarget(to: 0.05)
        #expect(left.target == .pane("p2", .left))
        #expect(!left.added.isEmpty, "the ring grows in with render-server springs")
        #expect(Set(left.added).isSubset(of: ["bounds.size", "cornerRadius", "position"]), "\(left.added)")
        #expect(!drag.root.highlightStepsOnFrames)
        // A pointer move inside the zone moves nothing.
        #expect(try drag.retarget(to: 0.07).added.isEmpty)

        var springs = left.added.count
        let zones: [(CGFloat, DropTarget)] = [(0.5, .pane("p2", .center)), (0.95, .pane("p2", .right))]
        for (x, zone) in zones {
            let before = try #require(drag.ring)
            let move = try drag.retarget(to: x)
            let paths = Drag.movedKeyPaths(from: before, to: try #require(drag.ring))
            #expect(move.target == zone)
            #expect(!paths.isEmpty, "\(zone) moves the ring")
            #expect(move.added == paths, "one additive spring per moved key path at \(zone): \(move.added) vs \(paths)")
            springs += move.added.count
            drag.frames()
        }
        #expect(drag.ringSpringKeys.count == springs, "a retarget stacks on the running springs; none is replaced")
        #expect(drag.replacingSprings == 0, "a replacing spring would pin the additive ones")
        #expect(drag.root.driver.startRequests == starts, "the three moves ask for no display frame")
        #expect(drag.highlight.renderServerMoves == 3, "one retarget per zone")
        #expect(drag.highlight.steps == 0, "advanceFrame no longer steps the highlight")
        #expect(!drag.highlight.isMoving)
        #expect(!drag.root.highlightStepsOnFrames)
        let rest = try #require(drag.highlight.outline?.ringFrame)
        let target = drag.highlight.destinationRect
        #expect(abs(rest.minX - target.minX) < 0.01 && abs(rest.minY - target.minY) < 0.01
                    && abs(rest.width - target.width) < 0.01 && abs(rest.height - target.height) < 0.01,
                "the model is at the target from the event's turn: \(rest) vs \(target)")
        drag.root.cancelTabDrag()
        #expect(!drag.highlight.isShowing)
        drag.frames()
        #expect(drag.highlight.steps == 0)
    }

    @Test func offTheHighlightMovesAndStepsAsBefore() throws {
        let drag = Drag(renderServer: false)
        defer { drag.close() }
        try drag.requireAnimates()
        try #require(drag.highlight.style == .outline)
        try drag.move(to: 0.05)
        try drag.move(to: 0.5)
        try drag.move(to: 0.95)
        #expect(drag.highlight.renderServerMoves == 0)
        #expect(drag.ringSpringKeys.isEmpty, "off, the ring has no render-server springs")
        #expect(drag.replacingSprings > 0, "off, the ring moves with its replacing springs")
        #expect(drag.root.highlightStepsOnFrames)
        drag.frames(2)
        #expect(drag.highlight.steps == 2)
        drag.root.cancelTabDrag()
    }

    @Test func aStyleTheCPUDrawsStillStepsWhileItMoves() throws {
        TunableStore.shared.set(DropOverlayTunables.style.key, .choice(DropOverlayStyle.hairline.rawValue))
        defer { TunableStore.shared.set(DropOverlayTunables.style.key, nil) }
        let drag = Drag(renderServer: true)
        defer { drag.close() }
        let starts = drag.root.driver.startRequests
        try drag.move(to: 0.05)
        try drag.move(to: 0.95)
        #expect(drag.highlight.style == .hairline)
        #expect(drag.highlight.renderServerMoves == 0, "the render server takes only a self-driven style")
        #expect(drag.root.driver.startRequests > starts, "a style the CPU draws asks for display frames")
        #expect(drag.highlight.isMoving)
        #expect(drag.root.highlightStepsOnFrames)
        for _ in 0..<600 where drag.highlight.isMoving { drag.frames(1) }
        #expect(drag.highlight.steps > 0)
        #expect(!drag.highlight.isMoving, "the springs land")
        #expect(!drag.root.highlightStepsOnFrames)
        drag.root.cancelTabDrag()
    }
}
