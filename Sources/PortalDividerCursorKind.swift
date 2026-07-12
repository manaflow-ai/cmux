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
        case .vertical: return Self.leftRightCursor
        case .horizontal: return Self.upDownCursor
        case .both: return Self.allAxesCursor
        }
    }

    /// All divider cursors are drawn with one arrow style so the single-axis
    /// and four-way affordances read as a family. AppKit's four-way move
    /// cursor is private and cannot be resolved by selector (on macOS 15 the
    /// class method exists but its implementation is a tombstone that raises
    /// `doesNotRecognizeSelector`, crashing on first use), and mixing the
    /// system resize glyphs with a drawn four-way made the corner cursor
    /// look off-family. Dark glyph with a white rim like system cursors.
    private static let leftRightCursor = drawnArrowsCursor(directions: [(1, 0), (-1, 0)])
    private static let upDownCursor = drawnArrowsCursor(directions: [(0, 1), (0, -1)])
    private static let allAxesCursor = drawnArrowsCursor(directions: [(0, 1), (0, -1), (1, 0), (-1, 0)])

    private static func drawnArrowsCursor(directions: [(dx: CGFloat, dy: CGFloat)]) -> NSCursor {
        let side: CGFloat = 24
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let path = arrowsPath(center: NSPoint(x: side / 2, y: side / 2), directions: directions)
            NSColor.white.setStroke()
            path.lineWidth = 2.5
            path.lineJoinStyle = .round
            path.stroke()
            NSColor.black.setFill()
            path.fill()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }

    /// Opposing arrows from the center: a shaft per axis plus a triangular
    /// head per direction. Sized for a 24pt cursor image.
    private static func arrowsPath(center c: NSPoint, directions: [(dx: CGFloat, dy: CGFloat)]) -> NSBezierPath {
        let tip: CGFloat = 8.5      // center -> arrow tip
        let headLength: CGFloat = 4.0
        let headHalfWidth: CGFloat = 3.0
        let shaftHalfWidth: CGFloat = 1.0

        let path = NSBezierPath()
        let base = tip - headLength
        if directions.contains(where: { $0.dx != 0 }) {
            path.appendRect(NSRect(
                x: c.x - base, y: c.y - shaftHalfWidth, width: base * 2, height: shaftHalfWidth * 2
            ))
        }
        if directions.contains(where: { $0.dy != 0 }) {
            path.appendRect(NSRect(
                x: c.x - shaftHalfWidth, y: c.y - base, width: shaftHalfWidth * 2, height: base * 2
            ))
        }
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
