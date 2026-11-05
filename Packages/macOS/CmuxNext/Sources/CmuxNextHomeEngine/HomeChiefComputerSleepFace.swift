import AppKit

/// The asleep computer's mark in the Computer section: a grey Chief with closed eyes and three z's
/// rising to its right (Lawrence's reference, 2026-11-04). A fixed grey, since it sits on the
/// card's translucent fill in both light and dark themes. Decorative: the note beside it says it.
@MainActor
final class HomeChiefComputerSleepFace: NSView {
    private static let grey = NSColor(white: 0.55, alpha: 1)
    private static let disc: CGFloat = 30
    /// The disc's center in the view (flipped); the z's take the room above and to the right.
    private static let center = NSPoint(x: 28, y: 30)

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 56, height: 45) }

    override func draw(_ dirtyRect: NSRect) {
        let center = Self.center
        Self.grey.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - Self.disc / 2, y: center.y - Self.disc / 2, width: Self.disc, height: Self.disc)).fill()
        NSColor(white: 0.13, alpha: 1).setFill()
        for side: CGFloat in [-1, 1] { Self.eye(at: NSPoint(x: center.x + side * 4.75, y: center.y - 0.2)) }
        // Oldest (highest, faintest) to newest.
        Self.z(at: NSPoint(x: center.x + 14.6, y: center.y - 27.2), width: 4.8, height: 5.4, line: 1, alpha: 0.3)
        Self.z(at: NSPoint(x: center.x + 22.5, y: center.y - 23.9), width: 4.6, height: 5, line: 1.25, alpha: 0.9)
        Self.z(at: NSPoint(x: center.x + 18.6, y: center.y - 18.7), width: 3.4, height: 3.75, line: 0.95, alpha: 0.65)
    }

    /// A closed eye: a soft lens with two lobes on top.
    private static func eye(at point: NSPoint) {
        NSBezierPath(ovalIn: NSRect(x: point.x - 3.35, y: point.y - 1.25, width: 6.7, height: 3.4)).fill()
        for side: CGFloat in [-1, 1] {
            NSBezierPath(ovalIn: NSRect(x: point.x + side * 1.6 - 1.6, y: point.y - 2.2, width: 3.2, height: 3.2)).fill()
        }
    }

    private static func z(at point: NSPoint, width: CGFloat, height: CGFloat, line: CGFloat, alpha: CGFloat) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: point.x - width / 2, y: point.y - height / 2))
        path.line(to: NSPoint(x: point.x + width / 2, y: point.y - height / 2))
        path.line(to: NSPoint(x: point.x - width / 2, y: point.y + height / 2))
        path.line(to: NSPoint(x: point.x + width / 2, y: point.y + height / 2))
        path.lineWidth = line
        path.lineJoinStyle = .miter
        grey.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }
}
