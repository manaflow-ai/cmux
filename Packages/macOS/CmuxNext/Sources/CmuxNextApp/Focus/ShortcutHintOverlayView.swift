import AppKit
import CmuxNextDesign

/// Click-through, immediate rectangular badges. Text contains only shortcut symbols.
final class ShortcutHintOverlayView: NSView {
    struct Hint {
        var text: String
        var rect: CGRect
    }

    var hints: [Hint] = [] { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        for hint in hints {
            let text = hint.text as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let size = text.size(withAttributes: attributes)
            let badge = CGRect(x: hint.rect.maxX - size.width - 10, y: hint.rect.midY - 8,
                               width: size.width + 8, height: 16).integral
            NSColor.windowBackgroundColor.setFill()
            let path = NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3)
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 0.5
            path.stroke()
            text.draw(at: CGPoint(x: badge.minX + 4, y: badge.midY - size.height / 2), withAttributes: attributes)
        }
    }
}
