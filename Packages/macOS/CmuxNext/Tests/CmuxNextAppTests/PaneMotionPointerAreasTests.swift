import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextLayout
import CmuxNextTestSupport
import ObjectiveC
import Testing

/// RESIZE MAIN BUDGET (cmux-ad m16 item 5; coordinator: Chrome's model, one native pointer path per window). Each pane
/// content view that owns an NSTrackingArea or cursor rects (the terminal surface, the tab strip, the toolbar, the
/// closing-mode watch, the strip scrollbar) made AppKit invalidate its cursor rects when its pane moved, walk the
/// window's views for cursor rects and rebuild the window's structural regions in the display cycle: the drag margins
/// with a constraint walk of the window's minimum size, and every tracking area. About 2.1-2.4 ms of each median
/// keys-held STRESS frame with motion.frameOwner.terminals on (Time Profiler of job b6c9633c, 120 Hz). The divider
/// handles already take their cursor and hover from the screen's one tracking area (DividerCursorNoRegionRebuildTests);
/// a moving pane must cost AppKit none of this either.
///
/// The counts need a window on screen (a display worker): off screen AppKit tracks nothing.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct PaneMotionPointerAreasTests {
    /// Counts, by the receiver's class, what AppKit does for pointer areas while the panes move: cursor-rect
    /// invalidations (`-[NSWindow invalidateCursorRectsForView:]`), tracking-area updates (`-[NSView updateTrackingAreas]`,
    /// reached by every override's `super`) and the window's drag-margin rebuilds (`-[NSWindow _resetDragMargins]`).
    enum Spy {
        static var invalidations: [String: Int] = [:]
        static var trackingUpdates: [String: Int] = [:]
        static var dragMarginResets = 0
        private static var originals: [(Method, IMP)] = []

        static func install() {
            invalidations = [:]
            trackingUpdates = [:]
            dragMarginResets = 0
            guard originals.isEmpty else { return }
            if let method = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.invalidateCursorRects(for:))) {
                let imp = method_getImplementation(method)
                typealias Fn = @convention(c) (AnyObject, Selector, NSView) -> Void
                let call = unsafeBitCast(imp, to: Fn.self)
                let block: @convention(block) (AnyObject, NSView) -> Void = { this, view in
                    MainActor.assumeIsolated { invalidations[String(describing: type(of: view)), default: 0] += 1 } // main-proof: AppKit calls it on main
                    call(this, #selector(NSWindow.invalidateCursorRects(for:)), view)
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
                originals.append((method, imp))
            }
            if let method = class_getInstanceMethod(NSView.self, #selector(NSView.updateTrackingAreas)) {
                let imp = method_getImplementation(method)
                typealias Fn = @convention(c) (AnyObject, Selector) -> Void
                let call = unsafeBitCast(imp, to: Fn.self)
                let block: @convention(block) (AnyObject) -> Void = { this in
                    MainActor.assumeIsolated { trackingUpdates[String(describing: type(of: this)), default: 0] += 1 } // main-proof: AppKit calls it on main
                    call(this, #selector(NSView.updateTrackingAreas))
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
                originals.append((method, imp))
            }
            // AppKit's private drag-margin rebuild (the min-size walk under it): counted only, never changed.
            let reset = NSSelectorFromString("_resetDragMargins")
            if let method = class_getInstanceMethod(NSWindow.self, reset) {
                let imp = method_getImplementation(method)
                typealias Fn = @convention(c) (AnyObject, Selector) -> Void
                let call = unsafeBitCast(imp, to: Fn.self)
                let block: @convention(block) (AnyObject) -> Void = { this in
                    MainActor.assumeIsolated { dragMarginResets += 1 } // main-proof: AppKit calls it on main
                    call(this, reset)
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
                originals.append((method, imp))
            }
        }

        static func uninstall() {
            for (method, imp) in originals { method_setImplementation(method, imp) }
            originals.removeAll()
        }

        static var line: String {
            func list(_ counts: [String: Int]) -> String { counts.sorted { $0.value > $1.value }.map { "\($0.key):\($0.value)" }.joined(separator: ",") }
            return "invalidations=\(invalidations.values.reduce(0, +)) [\(list(invalidations))] tracking_updates=\(trackingUpdates.values.reduce(0, +)) "
                + "[\(list(trackingUpdates))] drag_margin_resets=\(dragMarginResets)"
        }
    }

    /// Two columns of two terminal panes each (the bench's key layout): the column divider moves all four.
    static let grid: ScreenLayout = .columns([
        LayoutColumn(id: "c0", width: 0.5, root: .split("a", axis: .vertical, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))),
        LayoutColumn(id: "c1", width: 0.5, root: .split("b", axis: .vertical, ratio: 0.5, a: .leaf("p3"), b: .leaf("p4"))),
    ])

    /// The frames of one key resize (Ctrl-Shift-L on p2) with the terminals at their pane's size in every frame or held
    /// (`motion.frameOwner.terminals` on or off): AppKit invalidates no cursor rects, updates no tracking area and
    /// rebuilds no drag margins in them.
    @Test(arguments: [false, true])
    func aKeyResizeSpringCostsAppKitNoPointerAreaWork(ownFrames: Bool) throws {
        let rig = PaneGroundCoversPaneTests.Rig(Self.grid, focused: "p2")
        defer { rig.close() }
        defer { PaneGroundCoversPaneTests.releaseFrames() }
        try #require(PaneGroundCoversPaneTests.ownFrames(ownFrames), "motion.frameOwner.terminals did not take \(ownFrames)")
        rig.window.orderFrontRegardless()
        try #require(rig.window.isVisible, "the window is not on screen: this test needs a display worker")
        // At rest first: every view's tracking areas and cursor rects are in place before the press.
        rig.window.displayIfNeeded()
        CATransaction.flush()
        Spy.install()
        defer { Spy.uninstall() }
        try #require(PaneResize.press("p2", .right, model: rig.model, view: rig.root), "the press was refused")
        rig.root.syncWithModel()
        var frames = 0
        var moving = true
        while moving, frames < 240 {
            moving = rig.frame()
            rig.window.displayIfNeeded()
            CATransaction.flush()
            frames += 1
        }
        let inMotion = Spy.line
        rig.commit()
        rig.window.displayIfNeeded()
        CATransaction.flush()
        print("HPA-COUNT case=pane-motion-pointer-areas own_frames=\(ownFrames) frames=\(frames) motion: \(inMotion) with landing: \(Spy.line)")
        try #require(frames > 3, "the press did not spring (\(frames) frames)")
        #expect(Spy.invalidations.isEmpty, "\(frames) key-resize frames made AppKit invalidate cursor rects: \(inMotion)")
        #expect(Spy.trackingUpdates.isEmpty, "\(frames) key-resize frames updated tracking areas: \(inMotion)")
        #expect(Spy.dragMarginResets == 0, "\(frames) key-resize frames rebuilt the window's drag margins \(Spy.dragMarginResets) times")
    }
}
