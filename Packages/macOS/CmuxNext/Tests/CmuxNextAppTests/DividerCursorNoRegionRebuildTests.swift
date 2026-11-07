import AppKit
@testable import CmuxNextApp
@testable import CmuxNextLayout
import CmuxNextDesign
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

    /// A divider that springs away from a still pointer takes its resize cursor and hover with it, and the pointer at
    /// its new place gets them: both come from the current frames, never from where the handle was.
    @Test func theResizeCursorFollowsADividerThatMovesUnderAStillPointer() async throws {
        let columns = (0..<2).map { PaneMotionBench.column($0, rows: 3, width: 0.5) }
        let probe = LayoutWorkProbe(.columns(columns), focused: PaneID("p0-0"))
        defer { probe.close() }
        let screen = probe.screen
        let handle = try #require(screen.dividerViews[.split("s1-0")])
        let center = { CGPoint(x: handle.frame.midX, y: handle.frame.midY) }
        let old = center()
        probe.hoverAt = screen.convert(old, to: nil)
        screen.refreshDividerHover()
        #expect(handle.isHovered && screen.dividerPointer.shownCursor === handle.resizeCursor, "the pointer on the divider")
        #expect(NSCursor.current === handle.resizeCursor, "the app shows the resize cursor: \(NSCursor.current.debugName)")

        var next = columns
        next[1] = PaneMotionBench.column(1, rows: 2, width: 0.5)
        probe.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(next))])
        for _ in 0..<4 { await Task.yield() } // The layout syncs the model change on its observation turn.
        let frames = probe.settle()
        try #require(frames > 1, "the change started no spring")
        try #require(abs(center().y - old.y) > 40, "the divider did not move: \(old) -> \(center())")
        #expect(!handle.isHovered && screen.dividerPointer.shownCursor == nil, "the divider left the still pointer: no resize cursor at its old place")
        #expect(NSCursor.current !== handle.resizeCursor, "the app gave the resize cursor back: \(NSCursor.current.debugName)")

        probe.hoverAt = screen.convert(center(), to: nil)
        screen.refreshDividerHover()
        #expect(handle.isHovered && screen.dividerPointer.shownCursor === handle.resizeCursor, "the pointer at the divider's new place")
    }

    /// The screen's divider tracking area is installed once the screen is in a window (no geometry change needed): with
    /// none, no pointer event reaches the divider hover and the resize cursor never shows.
    @Test func theScreenHasItsDividerTrackingAreaInAWindow() throws {
        let probe = LayoutWorkProbe(.columns((0..<2).map { PaneMotionBench.column($0, rows: 1, width: 0.5) }), focused: PaneID("p0-0"))
        defer { probe.close() }
        let screen = probe.screen
        let areas = screen.trackingAreas.filter { $0.owner === screen.dividerPointer }
        #expect(areas.count == 1, "divider tracking areas on the screen: \(areas.count)")
        #expect(areas.first?.options.contains(.mouseMoved) == true && areas.first?.options.contains(.inVisibleRect) == true)
    }

    /// A screen that hides under a still pointer on its divider (a workspace switch) gives the resize cursor back: a
    /// hidden view gets no pointer events, and its handles did not move.
    @Test func aScreenThatHidesUnderThePointerGivesTheResizeCursorBack() throws {
        let columns = (0..<2).map { PaneMotionBench.column($0, rows: 2, width: 0.5) }
        let probe = LayoutWorkProbe(.columns(columns), focused: PaneID("p0-0"))
        defer { probe.close() }
        let screen = probe.screen
        let handle = try #require(screen.dividerViews[.split("s1-0")])
        probe.hoverAt = screen.convert(CGPoint(x: handle.frame.midX, y: handle.frame.midY), to: nil)
        screen.refreshDividerHover()
        try #require(screen.dividerPointer.shownCursor != nil, "the pointer on the divider")
        screen.isHidden = true
        #expect(!handle.isHovered && screen.dividerPointer.shownCursor == nil, "the hidden screen holds no resize cursor")
        #expect(NSCursor.current !== handle.resizeCursor, "the app gave the resize cursor back: \(NSCursor.current.debugName)")
    }

    /// AppKit sends `cursorUpdate` to the view under the pointer when it crosses a cursor area (a terminal's I-beam rect
    /// beside the handle): the handle answers with its resize cursor inside its clip, and leaves the cursor to the
    /// views under it outside the clip (the real-pointer journey px-divider-hover showed the I-beam on a divider).
    @Test func theHandleUnderThePointerAnswersACursorUpdateWithItsResizeCursor() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        window.contentView = parent
        let handle = DividerHandleView(kind: .split("x"), axis: .horizontal)
        handle.frame = CGRect(x: 100, y: 0, width: 8, height: 400)
        parent.addSubview(handle)
        handle.cursorClip = CGRect(x: 0, y: 0, width: 400, height: 300)
        func update(at point: CGPoint) throws {
            let event = try #require(NSEvent.enterExitEvent(with: .cursorUpdate, location: point, modifierFlags: [], timestamp: 0,
                                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                            trackingNumber: 0, userData: nil))
            handle.cursorUpdate(with: event)
        }
        NSCursor.iBeam.set()
        try update(at: CGPoint(x: 104, y: 100)) // inside the clip (window coordinates, bottom-left origin)
        #expect(NSCursor.current === handle.resizeCursor, "inside the clip: \(NSCursor.current.debugName)")
        NSCursor.iBeam.set()
        try update(at: CGPoint(x: 104, y: 350)) // under the dock
        #expect(NSCursor.current !== handle.resizeCursor, "under the dock: \(NSCursor.current.debugName)")
    }

    /// The pointer over a divider still gets the resize cursor, and over the part a dock covers it does not.
    @Test func thePointerOverADividerGetsTheResizeCursorInsideItsClipOnly() throws {
        let handle = DividerHandleView(kind: .split("x"), axis: .horizontal)
        handle.frame = CGRect(x: 100, y: 0, width: 8, height: 400)
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        parent.addSubview(handle)
        handle.cursorClip = CGRect(x: 0, y: 0, width: 400, height: 300)
        // The handle is flipped and its parent is not: local y 300 is the parent's y 100 (inside the clip), local y 50
        // the parent's y 350 (above the clip's top, under the dock).
        #expect(handle.cursorRectInBounds.contains(CGPoint(x: 4, y: 300)), "inside the clip: the resize cursor")
        #expect(!handle.cursorRectInBounds.contains(CGPoint(x: 4, y: 50)), "under the dock: no resize cursor")
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
