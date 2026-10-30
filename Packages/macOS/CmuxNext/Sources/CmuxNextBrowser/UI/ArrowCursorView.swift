public import AppKit
import CmuxNextCompat
public import CmuxNextDesign

/// A toolbar row that shows the arrow over its whole frame, the I-beam over
/// the omnibar's text area and the pointing hand over an enabled button
/// (`OmnibarPointer`). The buttons' own cursor rects (`ClickableButton`) sit
/// above the row's arrow rect in the key window; the row's pointer moves give
/// the same hand in any window state.
///
/// Cursor rects work only in the key window. A Chromium page is a child
/// window that takes the key while the page has the keyboard
/// (`WindowKeyFamily`), so the toolbar's rects did nothing and the arrow
/// stayed over the omnibar until a click made the parent key (Lawrence
/// 2026-10-13). The row also sets the cursor itself on every pointer move
/// over it, with a tracking area that works in any window state, and again
/// after the app handled a move while a child window has the key
/// (`pointerDidMove`). The rects stay for the key window; subviews with
/// their own rects (the editing omnibar text) take precedence inside it.
///
/// A still pointer: while a child window has the key, AppKit sets the
/// cursor for that window's tracking areas at the end of its display cycle
/// whenever they change (a Chromium page reloads or changes its own cursor),
/// and the pointer is outside that window, so it set the arrow over the
/// omnibar with no move to set the row's cursor again (input-host trace,
/// 2026-10-14: `-[_NSTrackingAreaAKManager setCursorForMouseLocation:]`
/// from `displayCycleUpdateStructuralRegions`). After each run loop pass the
/// row under the pointer sets its cursor again when another one shows
/// (`keepCursor`).
public class ArrowCursorView: NSView, ClickableCursorHost {
    private var cursorArea: NSTrackingArea?
    /// Owns the row's cursor tracking area, so the area's events end there
    /// and never travel up the responder chain (a tracking area keeps its
    /// owner unretained).
    private let cursorTracker = RowCursorTracker()
    /// The cursor the row last set on a pointer move (`debug.omnibar`).
    private(set) var trackedCursor: OmnibarPointer.Cursor?
    /// Where the pointer was, in window coordinates, when the row last set its cursor; nil once
    /// it left the row, the row hid (a parked tab) or the row left its window. Only a hint that
    /// the pointer may be over the row: `clickableStateDidChange` reads the pointer again.
    private(set) var pointerPoint: NSPoint?
    /// Where the pointer is now, in the row's window coordinates, when the row's window is the
    /// top window under it; nil otherwise. Tests replace it (no real pointer on a test host).
    var currentPointer: (ArrowCursorView) -> NSPoint? = { row in
        guard let window = row.window else { return nil }
        return ClickableButton.currentPointer(in: window)
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: OmnibarPointer.cursor(.toolbar).cursor)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // `.inVisibleRect` follows the view's visible rect: one area is enough. No
        // `.cursorUpdate`: AppKit sends a cursor update to the view under the pointer, which
        // may answer with the arrow (an input-host run with `.cursorUpdate` showed the arrow
        // past the end of the text in a window that was not key).
        guard cursorArea == nil else { return }
        cursorTracker.row = self
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: cursorTracker)
        addTrackingArea(area)
        cursorArea = area
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        pointerPoint = nil
    }

    /// Parking a tab hides its row under a still pointer, with no exit event.
    public override func viewDidHide() {
        super.viewDidHide()
        pointerPoint = nil
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pointerPoint = nil
        Self.rows.removeAll { $0.row == nil || $0.row === self }
        if window != nil {
            Self.rows.append(WeakRow(row: self))
            Self.installCursorKeeper()
        }
    }

    func setCursor(at point: NSPoint) {
        let cursor = OmnibarPointer.cursor(atWindowPoint: point, in: self)
        pointerPoint = point
        trackedCursor = cursor
        cursor.cursor.set()
    }

    fileprivate func pointerDidLeave() { pointerPoint = nil }

    /// A button under a still pointer was enabled or disabled (Back running out of history while a
    /// Chromium page has the key): the row's rule gives the new cursor at once, where
    /// `keepCursor` would keep the one it set last and the button's rects wait for the key.
    /// `pointerPoint` only says the pointer was over the row; an exit can be skipped (a hide, a
    /// menu's tracking loop), so the row reads the pointer again and sets a cursor only while it
    /// is inside the row's visible rect, in the top window under it, and the row shows.
    public func clickableStateDidChange(_ view: NSView) {
        guard pointerPoint != nil else { return }
        guard window != nil, let point = currentPointer(self),
              ClickableButton.cursorRect(of: self)?.contains(convert(point, from: nil)) == true else {
            pointerPoint = nil
            return
        }
        setCursor(at: point)
    }

    // MARK: After a move, while a child window has the key

    private struct WeakRow { weak var row: ArrowCursorView? }
    /// Rows in a window, so a move finds the row under the pointer without a view search.
    private static var rows: [WeakRow] = []

    /// Call after the app handled a pointer move (`NSApplication.sendEvent`).
    /// While a child window (a Chromium page) has the key, the key window's
    /// own handling of a move may set the arrow after the row's tracking
    /// event: the row under the pointer in a window that is not key sets its
    /// cursor again, last. Reads no event. With a top-level key window it
    /// returns after one property read; otherwise it compares the pointer
    /// with each row's visible rect, returns when the cursor already is the
    /// row's, and only then asks the window server for the window under the
    /// pointer. No allocation.
    public static func pointerDidMove() {
        guard let key = NSApp.keyWindow, key.parent != nil else { return }
        #if DEBUG
        let start = DispatchTime.now().uptimeNanoseconds
        defer { MoveHookStats.record(nanoseconds: DispatchTime.now().uptimeNanoseconds - start) }
        #endif
        let location = NSEvent.mouseLocation
        for entry in rows {
            guard let row = entry.row, let window = row.window, window !== key, window.isVisible else { continue }
            let point = window.convertPoint(fromScreen: location)
            guard row.visibleRect.contains(row.convert(point, from: nil)), !row.isHiddenOrHasHiddenAncestor else { continue }
            // Nothing to set: the row's tracking area already set this cursor, and no other
            // handling of the move replaced it.
            let cursor = OmnibarPointer.cursor(atWindowPoint: point, in: row)
            if NSCursor.current === cursor.cursor {
                row.trackedCursor = cursor
                return
            }
            guard isTopWindow(window, at: location) else { return }
            row.setCursor(at: point)
            return
        }
    }

    /// Whether `window` is the top window at `location` (screen coordinates). The window server
    /// answers synchronously (`SLSCopyWindowRoutingRecordsForScreenLocation`), which blocked the
    /// main thread for about half of every pointer move over a browser toolbar on a loaded Mac
    /// (sample of the live app, 2026-10-21): callers ask only when the cursor is not already the
    /// row's. The answer is never kept, since any window of any app can move over the toolbar.
    fileprivate static func isTopWindow(_ window: NSWindow, at location: NSPoint) -> Bool {
        NSWindow.windowNumber(at: location, belowWindowWithWindowNumber: 0) == window.windowNumber
    }
}

extension ArrowCursorView {
    // MARK: A still pointer, while a child window has the key

    private static var cursorKeeper: MainRunLoopObserver?

    /// One main run loop observer, after every other observer of the pass
    /// (AppKit's display cycle runs in Core Animation's commit, before it).
    /// Only a beforeWaiting observer: it runs in passes that other work started and never wakes
    /// the run loop itself (no timer, no re-post). `CMUX_NEXT_CURSOR_KEEPER=off` (DEBUG) leaves it
    /// out, for the idle comparison.
    private static func installCursorKeeper() {
        guard cursorKeeper == nil else { return }
        #if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_NEXT_CURSOR_KEEPER"] == "off" { return }
        #endif
        // It sets the cursor only, so the commit-boundary audit does not count it as late.
        cursorKeeper = MainRunLoopObserver(activities: .beforeWaiting, order: .max, drawsNothingAfterCommit: true) { _ in
            ArrowCursorView.keepCursor()
        }
    }

    /// With a top-level key window it returns after one property read. While
    /// a child window has the key it returns after one cursor comparison when
    /// the cursor is the one the row under the pointer set last; otherwise
    /// the row under the pointer sets its cursor again (the same checks as
    /// `pointerDidMove`). No allocation.
    private static func keepCursor() {
        guard let key = NSApp.keyWindow, key.parent != nil else { return }
        let location = NSEvent.mouseLocation
        for entry in rows {
            guard let row = entry.row, let window = row.window, window !== key, window.isVisible else { continue }
            let point = window.convertPoint(fromScreen: location)
            guard row.visibleRect.contains(row.convert(point, from: nil)), !row.isHiddenOrHasHiddenAncestor else { continue }
            guard NSCursor.current !== (row.trackedCursor ?? OmnibarPointer.cursor(.toolbar)).cursor else { return }
            guard isTopWindow(window, at: location) else { return }
            row.setCursor(at: point)
            return
        }
    }
}

#if DEBUG
/// What `pointerDidMove` costs past its first check (`debug.omnibar`'s `move_hook`).
enum MoveHookStats {
    @MainActor private(set) static var calls = 0
    @MainActor private(set) static var totalNanoseconds: UInt64 = 0
    @MainActor static func record(nanoseconds: UInt64) {
        calls += 1
        totalNanoseconds += nanoseconds
    }
}
#endif

/// The owner of `ArrowCursorView`'s cursor tracking area: an enter or a
/// move sets the row's cursor; nothing goes further. It reads
/// only `locationInWindow` of an enter or a move (a mouse event), never
/// `trackingArea` (AppKit raises on it for a move).
private final class RowCursorTracker: NSResponder {
    weak var row: ArrowCursorView?

    override func mouseEntered(with event: NSEvent) { row?.setCursor(at: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { row?.setCursor(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { row?.pointerDidLeave() }
}
