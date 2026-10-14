public import AppKit

/// Pointer moves outside a page go to the toolbar, not to the page.
///
/// AppKit sends every mouse move in a window to the window's first
/// responder, wherever the pointer is. After a click in a page, the page is
/// the first responder (a Chromium page in its own child window, which has
/// the key), so it also got the moves over the toolbar, and its engine set its
/// own cursor (the arrow) after the toolbar row set the I-beam: at rest the
/// arrow showed over the omnibar text (Lawrence 2026-10-14). While the
/// omnibar edits, its field editor is the first responder, which is why the
/// I-beam showed then.
///
/// Rules, for both engines (`WebKitWebView.mouseMoved`, and the app's event
/// dispatch for Chromium page windows):
/// - only a move outside the page's own frame is withheld; moves over the page
///   are untouched;
/// - the first move outside after one inside still goes to the page, so the
///   page leaves once and clears its hover;
/// - drags are other event types (`leftMouseDragged`), never withheld: a
///   selection or a drag that starts in the page follows the pointer anywhere.
/// No allocation; reads only `window` and `locationInWindow` of a move.
extension ArrowCursorView {
    /// Experiments for the at-rest cursor (DEBUG, `CMUX_NEXT_OMNIBAR_EXPERIMENT`, letters):
    /// `f` withholds page moves outside the page, `u` makes the row answer cursor updates,
    /// `r` keeps the row's arrow rect out of the omnibar text area. Release: none.
    static func experiment(_ letter: Character) -> Bool {
        #if DEBUG
        experiments.contains(letter)
        #else
        false
        #endif
    }

    #if DEBUG
    private static let experiments = ProcessInfo.processInfo.environment["CMUX_NEXT_OMNIBAR_EXPERIMENT"] ?? ""
    #endif

    static var withholdsOutsideMoves: Bool { experiment("f") }

    private static let chromiumWindowClasses: [AnyClass] = ["NativeWidgetMacNSWindow", "CefNSWindow"].compactMap(NSClassFromString)
    /// The Chromium page window the pointer was last inside (0: none), for the one leave.
    private static var chromiumWindowWithPointer = 0

    /// Whether the app should not dispatch `event`, a mouse move, at all: a
    /// move for a Chromium page window (a child window) outside that window,
    /// past the one leave. The caller then runs `pointerDidMove` itself.
    public static func withholdsPageMove(_ event: NSEvent) -> Bool {
        guard withholdsOutsideMoves, let window = event.window, window.parent != nil,
              chromiumWindowClasses.contains(where: { window.isKind(of: $0) }) else { return false }
        let point = event.locationInWindow
        let size = window.frame.size
        if point.x >= 0, point.y >= 0, point.x < size.width, point.y < size.height {
            chromiumWindowWithPointer = window.windowNumber
            return false
        }
        guard chromiumWindowWithPointer != window.windowNumber else {
            chromiumWindowWithPointer = 0
            return false
        }
        return true
    }

    /// Whether a page view takes a mouse move at `point` (in the view):
    /// inside `visibleRect`, or the first move outside after one inside
    /// (`hadPointer` keeps that state per view).
    static func pageTakesMove(at point: NSPoint, visibleRect: NSRect, hadPointer: inout Bool) -> Bool {
        let inside = visibleRect.contains(point)
        defer { hadPointer = inside }
        return inside || hadPointer || !withholdsOutsideMoves
    }
}
