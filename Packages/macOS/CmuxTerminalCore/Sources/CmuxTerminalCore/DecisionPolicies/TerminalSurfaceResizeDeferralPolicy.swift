public import AppKit

/// Pure decision for whether a terminal surface resize should be deferred
/// because an interactive drag (tab transfer / sidebar reorder) is in flight.
///
/// This is the terminal-domain home of `GhosttyNSView`'s resize-defer statics.
/// The view supplies the live AppKit conditions (interactive-geometry-resize
/// flag, drag-pasteboard presence, and the current event type) as plain values;
/// this type owns only the stateless classification.
public enum TerminalSurfaceResizeDeferralPolicy: Sendable {
    /// Whether an event type represents an in-flight mouse drag.
    public static func isDragResizeEvent(_ eventType: NSEvent.EventType?) -> Bool {
        switch eventType {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return true
        default:
            return false
        }
    }

    /// Whether an event type represents an in-flight mouse drag, used by the
    /// drag-logging gate. Identical classification to ``isDragResizeEvent(_:)``,
    /// kept as a distinct name so the debug logging call sites read clearly.
    public static func isDragMouseEvent(_ eventType: NSEvent.EventType?) -> Bool {
        switch eventType {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return true
        default:
            return false
        }
    }

    /// Whether a surface resize should be deferred for an active drag.
    ///
    /// The drag pasteboard can retain tab-transfer UTIs briefly after a split
    /// command or other layout churn. Only defer terminal resizes while an
    /// actual drag event is in flight; otherwise pre-existing panes can stay
    /// stuck at their old size. Interactive geometry resize already has an
    /// explicit fast path for sidebar and split-divider drags, so do not let
    /// stale drag-pasteboard state suppress those updates.
    public static func shouldDefer(
        interactiveGeometryResizeActive: Bool,
        hasTabDragPasteboardTypes: Bool,
        currentEventType: NSEvent.EventType?
    ) -> Bool {
        if interactiveGeometryResizeActive {
            return false
        }
        guard hasTabDragPasteboardTypes else { return false }
        return isDragResizeEvent(currentEventType)
    }
}
