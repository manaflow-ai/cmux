import AppKit
import CmuxNextDesign

/// A conversation's avatar as Messages draws it: initials in white on a muted
/// gradient disc; a group is a dark disc holding up to three member discs
/// with an initials badge. Interim view (the vendored MessagesLab sidebar
/// replaces it); it draws only what `HomeSidebarItem` says.
final class HomeAvatarView: NSView {
    private var avatars: [HomeAvatar] = []
    private var isGroup = false
    private var badge: String?

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    func show(_ item: HomeSidebarItem) {
        avatars = item.avatars
        isGroup = item.isGroup
        badge = item.badge
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.width, bounds.height)
        let disc = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        guard isGroup, avatars.count > 1 else {
            Self.drawInitials(avatars.first?.initials ?? "?", in: disc)
            return
        }
        // The group disc: a dark circle with the members inside it.
        NSColor(white: 0.18, alpha: 1).setFill()
        NSBezierPath(ovalIn: disc).fill()
        let small = side * 0.42
        let slots: [NSPoint] = [
            NSPoint(x: disc.minX + side * 0.14, y: disc.minY + side * 0.12),
            NSPoint(x: disc.minX + side * 0.50, y: disc.minY + side * 0.30),
            NSPoint(x: disc.minX + side * 0.28, y: disc.minY + side * 0.56),
        ]
        for (avatar, origin) in zip(avatars.prefix(3), slots) {
            Self.drawInitials(avatar.initials, in: NSRect(origin: origin, size: NSSize(width: small, height: small)))
        }
        if let badge {
            let size = side * 0.34
            let rect = NSRect(x: disc.maxX - size * 1.05, y: disc.maxY - size * 1.05, width: size, height: size)
            NSColor(white: 0.18, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: -1.5, dy: -1.5)).fill()
            Self.drawInitials(badge, in: rect)
        }
    }

    /// The Messages gradient (a muted violet gray) with the initials centered.
    static func drawInitials(_ initials: String, in rect: NSRect) {
        let path = NSBezierPath(ovalIn: rect)
        let gradient = NSGradient(starting: NSColor(srgbRed: 0.43, green: 0.41, blue: 0.52, alpha: 1),
                                  ending: NSColor(srgbRed: 0.29, green: 0.27, blue: 0.37, alpha: 1))
        gradient?.draw(in: path, angle: -90)
        let letters = String(initials.prefix(2))
        let font = NSFont.systemFont(ofSize: rect.height * (letters.count > 1 ? 0.40 : 0.48), weight: .semibold)
        let text = NSAttributedString(string: letters, attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = text.size()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}
