import AppKit

/// Orientation of a hovered split divider and the resize cursor it shows.
/// Shared by the portal host views and the hosted web-inspector divider.
/// `.both` marks the intersection square where a vertical and a horizontal
/// divider band overlap and a drag resizes along both axes.
enum PortalDividerCursorKind: Equatable {
    case vertical
    case horizontal
    case both

    var cursor: NSCursor {
        switch self {
        case .vertical: return .resizeLeftRight
        case .horizontal: return .resizeUpDown
        case .both: return Self.allAxesCursor
        }
    }

    /// AppKit ships no public four-way resize cursor, and the private
    /// `_moveCursor` cannot be resolved by selector: on macOS 15 the class
    /// method exists (`responds(to:)` is true) but its implementation is a
    /// tombstone that raises `doesNotRecognizeSelector`, crashing the app the
    /// moment the cursor is first used. Draw the classic four-directions
    /// move cursor (N/S/E/W arrows meeting at the center, dark glyph with a
    /// white rim like the system resize cursors) with bezier paths, so it
    /// needs no symbol or private API at all.
    private static let allAxesCursor: NSCursor = {
        let side: CGFloat = 24
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let path = fourDirectionsArrowsPath(center: NSPoint(x: side / 2, y: side / 2))
            NSColor.white.setStroke()
            path.lineWidth = 3
            path.lineJoinStyle = .round
            path.stroke()
            NSColor.black.setFill()
            path.fill()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }()

    /// Cross of four arrows: shafts from the center with a triangular head
    /// per compass direction. Sized for a 24pt cursor image.
    private static func fourDirectionsArrowsPath(center c: NSPoint) -> NSBezierPath {
        let tip: CGFloat = 10.5      // center -> arrow tip
        let headLength: CGFloat = 4.5
        let headHalfWidth: CGFloat = 3.6
        let shaftHalfWidth: CGFloat = 1.2

        let path = NSBezierPath()
        // Shafts (one cross: horizontal + vertical bars up to the head bases).
        let base = tip - headLength
        path.appendRect(NSRect(
            x: c.x - base, y: c.y - shaftHalfWidth, width: base * 2, height: shaftHalfWidth * 2
        ))
        path.appendRect(NSRect(
            x: c.x - shaftHalfWidth, y: c.y - base, width: shaftHalfWidth * 2, height: base * 2
        ))
        // Heads: (unit direction, per-direction perpendicular).
        let directions: [(dx: CGFloat, dy: CGFloat)] = [(0, 1), (0, -1), (1, 0), (-1, 0)]
        for d in directions {
            let tipPoint = NSPoint(x: c.x + d.dx * tip, y: c.y + d.dy * tip)
            let basePoint = NSPoint(x: c.x + d.dx * base, y: c.y + d.dy * base)
            let perp = NSPoint(x: -d.dy, y: d.dx)
            let head = NSBezierPath()
            head.move(to: tipPoint)
            head.line(to: NSPoint(x: basePoint.x + perp.x * headHalfWidth, y: basePoint.y + perp.y * headHalfWidth))
            head.line(to: NSPoint(x: basePoint.x - perp.x * headHalfWidth, y: basePoint.y - perp.y * headHalfWidth))
            head.close()
            path.append(head)
        }
        return path
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
