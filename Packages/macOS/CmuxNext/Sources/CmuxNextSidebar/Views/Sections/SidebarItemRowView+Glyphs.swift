import AppKit
import CmuxNextDesign

/// The glyphs an item draws without an icon: an emoji, or its title's first letter.
extension SidebarItemRowView {
    /// `emoji` drawn as a text glyph filling a `side` square (in color, not a template).
    static func emojiImage(_ emoji: String, side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let text = NSAttributedString(string: emoji, attributes: [.font: Typography.system(size: side * 0.85)])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
    }

    /// The first letter of `title` as a template glyph filling a `side` square (it takes the
    /// glyph tint); nil for an empty title.
    static func initialImage(_ title: String, side: CGFloat) -> NSImage? {
        guard let first = title.trimmingCharacters(in: .whitespacesAndNewlines).first else { return nil }
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let font = Typography.system(size: side * 0.72, weight: .semibold)
            let text = NSAttributedString(string: String(first).localizedUppercase, attributes: [.font: font, .foregroundColor: NSColor.black])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
        image.isTemplate = true
        return image
    }
}
