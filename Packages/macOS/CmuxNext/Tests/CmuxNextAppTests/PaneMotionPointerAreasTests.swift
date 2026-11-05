import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTabs
import CmuxNextTerminal
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
    /// Counts, by the receiver's class, what pointer areas cost while the panes move: cursor-rect invalidations
    /// (`-[NSWindow invalidateCursorRectsForView:]`), tracking areas added (`-[NSView addTrackingArea:]`: a view that owns
    /// one removes and adds it at each update) and the window's drag-margin rebuilds (`-[NSWindow _resetDragMargins]`).
    /// `trackingUpdates` (`-[NSView updateTrackingAreas]`) is only printed: AppKit calls it on every view of a moved
    /// subtree, whether it owns an area or not (PaneClipView, PaneHostView own none), and no view can stop that.
    enum Spy {
        static var invalidations: [String: Int] = [:]
        static var trackingUpdates: [String: Int] = [:]
        static var areasAdded: [String: Int] = [:]
        static var dragMarginResets = 0
        private static var originals: [(Method, IMP)] = []

        static func install() {
            invalidations = [:]
            trackingUpdates = [:]
            areasAdded = [:]
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
            if let method = class_getInstanceMethod(NSView.self, #selector(NSView.addTrackingArea(_:))) {
                let imp = method_getImplementation(method)
                typealias Fn = @convention(c) (AnyObject, Selector, NSTrackingArea) -> Void
                let call = unsafeBitCast(imp, to: Fn.self)
                let block: @convention(block) (AnyObject, NSTrackingArea) -> Void = { this, area in
                    MainActor.assumeIsolated { areasAdded[String(describing: type(of: this)), default: 0] += 1 } // main-proof: AppKit calls it on main
                    call(this, #selector(NSView.addTrackingArea(_:)), area)
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
            return "invalidations=\(invalidations.values.reduce(0, +)) [\(list(invalidations))] areas_added=\(areasAdded.values.reduce(0, +)) "
                + "[\(list(areasAdded))] tracking_updates=\(trackingUpdates.values.reduce(0, +)) [\(list(trackingUpdates))] "
                + "drag_margin_resets=\(dragMarginResets)"
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
    /// The rig's layout in the app's window (titled and resizable: a borderless one has no drag margins to rebuild).
    static func shellWindow(_ rig: PaneGroundCoversPaneTests.Rig) -> ShellWindow {
        let window = ShellWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = rig.root
        rig.root.layoutSubtreeIfNeeded()
        return window
    }

    @Test(arguments: [false, true])
    func aKeyResizeSpringCostsAppKitNoPointerAreaWork(ownFrames: Bool) throws {
        let rig = PaneGroundCoversPaneTests.Rig(Self.grid, focused: "p2")
        defer { rig.close() }
        defer { PaneGroundCoversPaneTests.releaseFrames() }
        try #require(PaneGroundCoversPaneTests.ownFrames(ownFrames), "motion.frameOwner.terminals did not take \(ownFrames)")
        let window = Self.shellWindow(rig)
        defer { window.closeAfterTest() }
        window.orderFrontRegardless()
        try #require(window.isVisible, "the window is not on screen: this test needs a display worker")
        // At rest first: every view's tracking areas and cursor rects are in place before the press.
        window.displayIfNeeded()
        CATransaction.flush()
        Spy.install()
        defer { Spy.uninstall() }
        try #require(PaneResize.press("p2", .right, model: rig.model, view: rig.root), "the press was refused")
        rig.root.syncWithModel()
        var frames = 0
        var moving = true
        while moving, frames < 240 {
            moving = rig.frame()
            window.displayIfNeeded()
            CATransaction.flush()
            frames += 1
        }
        let inMotion = Spy.line
        rig.commit()
        window.displayIfNeeded()
        CATransaction.flush()
        print("HPA-COUNT case=pane-motion-pointer-areas own_frames=\(ownFrames) frames=\(frames) motion: \(inMotion) with landing: \(Spy.line)")
        try #require(frames > 3, "the press did not spring (\(frames) frames)")
        #expect(Spy.invalidations.isEmpty, "\(frames) key-resize frames made AppKit invalidate cursor rects: \(inMotion)")
        #expect(Spy.areasAdded.isEmpty, "\(frames) key-resize frames re-added tracking areas: \(inMotion)")
        #expect(Spy.dragMarginResets == 0, "\(frames) key-resize frames rebuilt the window's drag margins \(Spy.dragMarginResets) times")
    }

    /// The first view of type `T` in `view`'s subtree.
    static func first<T: NSView>(_: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews { if let match = first(T.self, in: child) { return match } }
        return nil
    }

    /// The cursor over a terminal is the one it asks for (the I-beam), and over its tab strip the arrow, before and after
    /// a key resize; the terminal hears the pointer. The screen's one tracking area sets them from its hit test, as the
    /// terminal's own cursor rect did.
    @Test func theCursorOverATerminalAndItsStripIsTheSameBeforeAndAfterAKeyResize() throws {
        let rig = PaneGroundCoversPaneTests.Rig(Self.grid, focused: "p2")
        defer { rig.close() }
        let window = Self.shellWindow(rig)
        defer { window.closeAfterTest() }
        window.orderFrontRegardless()
        try #require(window.isVisible, "the window is not on screen: this test needs a display worker")
        window.displayIfNeeded()
        let screen = try rig.screen
        let host = try #require(rig.root.context.hosts["p1"])
        let surface = try #require(Self.first(TerminalSurfaceView.self, in: host), "p1 shows no terminal")
        let strip = try #require(Self.first(TabStripView.self, in: host), "p1 shows no tab strip")
        func move(over view: NSView) throws -> NSCursor {
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 0, pressure: 0))
            screen.dividerPointer.mouseMoved(with: event)
            return NSCursor.current
        }
        #expect(try move(over: surface) === NSCursor.iBeam, "over the terminal at rest: \(NSCursor.current.debugName)")
        #expect(screen.dividerPointer.contentTarget === surface, "the terminal did not hear the pointer")
        #expect(try move(over: strip) === NSCursor.arrow, "over the strip at rest: \(NSCursor.current.debugName)")

        try #require(PaneResize.press("p2", .right, model: rig.model, view: rig.root), "the press was refused")
        rig.root.syncWithModel()
        var frames = 0
        while frames < 240, rig.frame() { frames += 1 }
        rig.commit()
        try #require(frames > 3, "the press did not spring (\(frames) frames)")
        #expect(try move(over: surface) === NSCursor.iBeam, "over the terminal after the resize: \(NSCursor.current.debugName)")
        #expect(screen.dividerPointer.contentTarget === surface, "the terminal did not hear the pointer after the resize")
        #expect(try move(over: strip) === NSCursor.arrow, "over the strip after the resize: \(NSCursor.current.debugName)")
    }
}
