import AppKit

/// cmux: one person who has the conversation open, as the header draws them: a letter on their
/// own color (chat multiplayer, hq plans/cmux-next/chat-multiplayer/DESIGN.md; the agent chat's
/// `PresenceStack`, Faces.tsx).
public struct PaneHeaderFace: Equatable, Sendable {
    public var initial: String
    public var color: NSColor

    public init(initial: String, color: NSColor) {
        self.initial = initial
        self.color = color
    }
}

/// cmux: who else has the conversation open, beside the name pill: up to three overlapping faces,
/// then "+N". Drawn, not interactive (the header's clicks pass through it).
final class PaneHeaderFacesView: NSView {
    /// Faces drawn before "+N", as the agent chat's header (`PRESENCE_STACK`).
    static let shown = 3
    static let size: CGFloat = 20
    /// How much each face covers the one before it.
    static let overlap: CGFloat = 5
    /// Made once (no font made while drawing, crash ratchet `render_font`).
    private static let letterFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
    private static let moreFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

    var faces: [PaneHeaderFace] = [] {
        didSet {
            guard faces != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    /// The header's background behind the faces: each face's ring, so overlapping faces read apart.
    var ring: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let count = min(faces.count, Self.shown)
        guard count > 0 else { return .zero }
        var width = Self.size + CGFloat(count - 1) * (Self.size - Self.overlap)
        if let more = moreText { width += 4 + more.size().width }
        return NSSize(width: ceil(width), height: Self.size)
    }

    private var moreText: NSAttributedString? {
        let rest = faces.count - Self.shown
        guard rest > 0 else { return nil }
        return NSAttributedString(string: "+\(rest)", attributes: [
            .font: Self.moreFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let s = Self.size
        var x: CGFloat = 0
        for face in faces.prefix(Self.shown) {
            let disc = CGRect(x: x, y: 0, width: s, height: s)
            ring.setFill()
            NSBezierPath(ovalIn: disc.insetBy(dx: -1.5, dy: -1.5)).fill()
            face.color.setFill()
            NSBezierPath(ovalIn: disc).fill()
            let letter = NSAttributedString(string: face.initial, attributes: [
                .font: Self.letterFont,
                .foregroundColor: NSColor.white,
            ])
            let size = letter.size()
            letter.draw(at: CGPoint(x: disc.midX - size.width / 2, y: disc.midY - size.height / 2))
            x += s - Self.overlap
        }
        if let more = moreText {
            let size = more.size()
            more.draw(at: CGPoint(x: x + Self.overlap + 4, y: (s - size.height) / 2))
        }
    }
}
