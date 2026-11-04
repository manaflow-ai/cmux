import AppKit
@testable import CmuxNextApp
@testable import CmuxNextLayout
import Foundation
import ObjectiveC
import Testing

/// HOT PATH AUDIT frames (motion-frame, drag-frame): a divider set its resize cursor with AppKit cursor rects. A
/// divider that moves in a spring frame, and the cursor clip `applyPresentation` sets on it every frame, made AppKit
/// invalidate its cursor rects, and each invalidation scheduled a rebuild of the window's structural regions (drag
/// margins and the constraint min-size walk of every view: 14.6 % of a STRESS divider drag's busy main-thread time,
/// fleet job 02225774; 206 invalidations in 36 frames of a 12-pane spring, job 8d0c5e73). A divider's own tracking
/// area did the same (240 in 36 frames, job b971c2f8; with neither, 0: job 5146dc44). The screen's one tracking area,
/// which does not move, now hit-tests the current divider frames for the hover and the resize cursor
/// (`ScreenDividerPointer`), as Chrome sets the cursor from the hit test of each mouse event: a spring frame
/// invalidates no divider's cursor rects, and no AppKit call is skipped. The count needs a window on screen (a display
/// worker): off screen AppKit tracks nothing.
@MainActor @Suite(.serialized, .closesItsWindows)
struct DividerCursorNoRegionRebuildTests {
    @Test func aSpringFrameInvalidatesNoDividerCursorRects() async throws {
        let columns = (0..<4).map { PaneMotionBench.column($0, rows: 3, width: 0.25) }
        let probe = LayoutWorkProbe(.columns(columns), focused: PaneID("p0-0"))
        defer { probe.close() }
        var next = columns
        next[1] = PaneMotionBench.column(1, rows: 2, width: 0.25)
        probe.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(next))])
        for _ in 0..<4 { await Task.yield() }
        probe.window.orderFrontRegardless()
        try #require(probe.window.isVisible, "the window is not on screen: this test needs a display worker")
        CursorRectSpy.install()
        defer { CursorRectSpy.uninstall() }
        var frames = 0, moving = true
        while moving, frames < 120 {
            moving = probe.root.advanceFrame(1.0 / 120)
            frames += 1
            probe.window.contentView?.layoutSubtreeIfNeeded()
            probe.window.displayIfNeeded()
            CATransaction.flush()
        }
        print("HPA-COUNT case=divider-cursor-rects frames=\(frames) divider_invalidations=\(CursorRectSpy.dividers) all_invalidations=\(CursorRectSpy.all)")
        try #require(frames > 1, "the change started no spring")
        #expect(CursorRectSpy.dividers == 0, "\(frames) spring frames invalidated divider cursor rects \(CursorRectSpy.dividers) times")
    }
}

/// Counts `-[NSWindow invalidateCursorRectsForView:]` calls, and those for divider handles (test only).
@MainActor
enum CursorRectSpy {
    static var all = 0
    static var dividers = 0
    private static var original: (Method, IMP)?

    static func install() {
        all = 0
        dividers = 0
        guard original == nil, let method = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.invalidateCursorRects(for:))) else { return }
        let imp = method_getImplementation(method)
        typealias Fn = @convention(c) (AnyObject, Selector, NSView) -> Void
        let call = unsafeBitCast(imp, to: Fn.self)
        let selector = #selector(NSWindow.invalidateCursorRects(for:))
        let block: @convention(block) (AnyObject, NSView) -> Void = { this, view in
            MainActor.assumeIsolated { // main-proof: AppKit invalidates cursor rects on the main thread
                all += 1
                if view is DividerHandleView { dividers += 1 }
            }
            call(this, selector, view)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        original = (method, imp)
    }

    static func uninstall() {
        if let (method, imp) = original { method_setImplementation(method, imp) }
        original = nil
    }
}
