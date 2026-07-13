import AppKit
import Bonsplit
import CmuxAppKitSupportUI

/// Orientation of a hovered split divider and the resize cursor it shows.
/// Shared by the portal host views and the hosted web-inspector divider.
/// `.both` marks the intersection square where a vertical and a horizontal
/// divider band overlap and a drag resizes along both axes. Cursors come
/// from the drawn NSCursor.cmuxResize* family so every resize affordance in
/// the app reads as one visual set.
enum PortalDividerCursorKind: Equatable {
    case vertical
    case horizontal
    case both

    @MainActor
    var cursor: NSCursor {
        switch self {
        case .vertical: return NSCursor.cmuxResizeLeftRight
        case .horizontal: return NSCursor.cmuxResizeUpDown
        case .both: return NSCursor.cmuxResizeAllAxes
        }
    }

    /// Idempotently hands the drawn family to bonsplit so native
    /// NSSplitView divider cursor rects match: they otherwise register the
    /// system cursors underneath the portals' rects and can win AppKit's
    /// undefined overlap order, flashing the old glyphs.
    @MainActor
    static func injectBonsplitDividerCursors() {
        guard BonsplitDividerCursors.vertical == nil else { return }
        BonsplitDividerCursors.vertical = NSCursor.cmuxResizeLeftRight
        BonsplitDividerCursors.horizontal = NSCursor.cmuxResizeUpDown
    }

    /// Pointer-hover event types that the portal hosts claim inside the
    /// corner zone so underlying views cannot flicker their own cursors.
    static func isPointerHoverEvent(_ type: NSEvent.EventType?) -> Bool {
        switch type {
        case .mouseMoved, .cursorUpdate, .mouseEntered, .mouseExited: return true
        default: return false
        }
    }

}
