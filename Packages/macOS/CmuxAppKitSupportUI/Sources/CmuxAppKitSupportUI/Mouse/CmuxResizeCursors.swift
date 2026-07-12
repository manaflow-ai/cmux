public import AppKit

/// The one resize-cursor family for every cmux resize affordance: split
/// dividers, the divider corner (four-way), sidebar resizers, canvas pane
/// edges and corners, and popover resize handles.
///
/// Drawn with bezier paths — dark glyph with a white rim like the system
/// cursors — because AppKit ships no public four-way or diagonal resize
/// cursors and the private ones cannot be resolved by selector (on recent
/// macOS the class methods exist but their implementations are tombstones
/// that raise `doesNotRecognizeSelector`, crashing on first use). Mixing the
/// remaining system glyphs with drawn ones read as two visual families, so
/// every variant is drawn.
public extension NSCursor {
    @MainActor static var cmuxResizeLeftRight: NSCursor { cmuxLeftRightCursor }
    @MainActor static var cmuxResizeUpDown: NSCursor { cmuxUpDownCursor }
    @MainActor static var cmuxResizeAllAxes: NSCursor { cmuxAllAxesCursor }
    /// Northwest–southeast diagonal (top-left/bottom-right corners).
    @MainActor static var cmuxResizeDiagonalNWSE: NSCursor { cmuxDiagonalNWSECursor }
    /// Northeast–southwest diagonal (top-right/bottom-left corners).
    @MainActor static var cmuxResizeDiagonalNESW: NSCursor { cmuxDiagonalNESWCursor }
}

@MainActor private let cmuxLeftRightCursor = arrowsCursor(directions: [CGVector(dx: 1, dy: 0), CGVector(dx: -1, dy: 0)])
@MainActor private let cmuxUpDownCursor = arrowsCursor(directions: [CGVector(dx: 0, dy: 1), CGVector(dx: 0, dy: -1)])
@MainActor private let cmuxAllAxesCursor = arrowsCursor(directions: [
    CGVector(dx: 0, dy: 1), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0), CGVector(dx: -1, dy: 0),
])
@MainActor private let cmuxDiagonalNWSECursor = arrowsCursor(directions: [
    CGVector(dx: -0.7071, dy: 0.7071), CGVector(dx: 0.7071, dy: -0.7071),
])
@MainActor private let cmuxDiagonalNESWCursor = arrowsCursor(directions: [
    CGVector(dx: 0.7071, dy: 0.7071), CGVector(dx: -0.7071, dy: -0.7071),
])

@MainActor
private func arrowsCursor(directions: [CGVector]) -> NSCursor {
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

/// Opposing arrows from the center: one shaft per axis plus a triangular
/// head per direction. Direction vectors must be unit length. Sized for a
/// 24pt cursor image.
private func arrowsPath(center c: NSPoint, directions: [CGVector]) -> NSBezierPath {
    let tip: CGFloat = 8.5      // center -> arrow tip
    let headLength: CGFloat = 4.0
    let headHalfWidth: CGFloat = 3.0
    let shaftHalfWidth: CGFloat = 1.0
    let base = tip - headLength

    let path = NSBezierPath()
    var shaftAxes: [CGVector] = []
    for d in directions {
        let isKnownAxis = shaftAxes.contains {
            abs($0.dx - d.dx) + abs($0.dy - d.dy) < 0.01 || abs($0.dx + d.dx) + abs($0.dy + d.dy) < 0.01
        }
        if isKnownAxis { continue }
        shaftAxes.append(d)
        let perp = CGVector(dx: -d.dy, dy: d.dx)
        let shaft = NSBezierPath()
        shaft.move(to: NSPoint(x: c.x - d.dx * base + perp.dx * shaftHalfWidth, y: c.y - d.dy * base + perp.dy * shaftHalfWidth))
        shaft.line(to: NSPoint(x: c.x + d.dx * base + perp.dx * shaftHalfWidth, y: c.y + d.dy * base + perp.dy * shaftHalfWidth))
        shaft.line(to: NSPoint(x: c.x + d.dx * base - perp.dx * shaftHalfWidth, y: c.y + d.dy * base - perp.dy * shaftHalfWidth))
        shaft.line(to: NSPoint(x: c.x - d.dx * base - perp.dx * shaftHalfWidth, y: c.y - d.dy * base - perp.dy * shaftHalfWidth))
        shaft.close()
        path.append(shaft)
    }
    for d in directions {
        let tipPoint = NSPoint(x: c.x + d.dx * tip, y: c.y + d.dy * tip)
        let basePoint = NSPoint(x: c.x + d.dx * base, y: c.y + d.dy * base)
        let perp = CGVector(dx: -d.dy, dy: d.dx)
        let head = NSBezierPath()
        head.move(to: tipPoint)
        head.line(to: NSPoint(x: basePoint.x + perp.dx * headHalfWidth, y: basePoint.y + perp.dy * headHalfWidth))
        head.line(to: NSPoint(x: basePoint.x - perp.dx * headHalfWidth, y: basePoint.y - perp.dy * headHalfWidth))
        head.close()
        path.append(head)
    }
    return path
}
