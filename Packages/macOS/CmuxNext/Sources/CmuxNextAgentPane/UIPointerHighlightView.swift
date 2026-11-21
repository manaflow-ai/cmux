public import AppKit
import CmuxNextDesign
/// The outline over the native element being pointed at, with a chip naming it ("Tab · notes.md"). It never
/// takes the mouse; one is reused for the whole pick.
@MainActor
public final class UIPointerHighlightView: NSView {
    /// How the outline draws: `outline` (tint and 2pt ring, the default), `filled` (a stronger tint), `brackets`
    /// (corner marks only, the content stays clear).
    public enum Look: String, CaseIterable { case outline, filled, brackets }

    public private(set) var look: Look = .outline
    public private(set) var chip = ""
    private var box = NSRect.zero

    public static let chipHeight: CGFloat = 18

    /// The overlay's frame for an element at `frame` (window coordinates): the element plus the chip, above it
    /// when there is room, else below.
    public static func frame(around frame: NSRect, in window: NSWindow) -> NSRect {
        let height = window.contentView?.bounds.height ?? window.frame.height
        let ring = frame.insetBy(dx: -2, dy: -2)
        let above = ring.maxY + chipHeight + 2 <= height
        let chip = NSRect(x: ring.minX, y: above ? ring.maxY + 2 : ring.minY - chipHeight - 2,
                          width: max(ring.width, 160), height: chipHeight)
        return ring.union(chip)
    }

    public func show(_ element: UIPointerNativeElement, look: Look, outlineIn rect: NSRect, around frame: NSRect) {
        self.look = look
        chip = "\(element.kind.rawValue) · \(element.title)"
        box = frame.insetBy(dx: -2, dy: -2).offsetBy(dx: -rect.minX, dy: -rect.minY)
        setFrameSize(rect.size)
        needsDisplay = true
    }

    override public func draw(_ dirtyRect: NSRect) {
        let blue = NSColor.systemBlue
        switch look {
        case .outline:
            blue.withAlphaComponent(0.15).setFill()
            box.fill()
            let ring = NSBezierPath(rect: box.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            blue.setStroke()
            ring.stroke()
        case .filled:
            blue.withAlphaComponent(0.32).setFill()
            box.fill()
            blue.setStroke()
            NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5)).stroke()
        case .brackets:
            let arm = min(10, box.width / 3, box.height / 3)
            let path = NSBezierPath()
            let r = box.insetBy(dx: 1, dy: 1)
            for (corner, dx, dy) in [(NSPoint(x: r.minX, y: r.minY), arm, arm), (NSPoint(x: r.maxX, y: r.minY), -arm, arm),
                                     (NSPoint(x: r.minX, y: r.maxY), arm, -arm), (NSPoint(x: r.maxX, y: r.maxY), -arm, -arm)] {
                path.move(to: NSPoint(x: corner.x + dx, y: corner.y))
                path.line(to: corner)
                path.line(to: NSPoint(x: corner.x, y: corner.y + dy))
            }
            path.lineWidth = 2.5
            blue.setStroke()
            path.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: TypeScale.caption, weight: TypeScale.emphasis), .foregroundColor: NSColor.white]
        let text = NSAttributedString(string: chip, attributes: attributes)
        let above = box.maxY + 2 + Self.chipHeight <= bounds.height + 0.5
        let width = min(ceil(text.size().width) + 12, bounds.width)
        let pill = NSRect(x: box.minX, y: above ? box.maxY + 2 : box.minY - Self.chipHeight - 2, width: width, height: Self.chipHeight)
        blue.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
        text.draw(with: pill.insetBy(dx: 6, dy: 2), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override public func hitTest(_ point: NSPoint) -> NSView? { nil }
}
