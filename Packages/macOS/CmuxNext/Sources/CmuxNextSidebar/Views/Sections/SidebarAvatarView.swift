import AppKit
import CmuxNextDesign

/// The sidebar's profile control (SIDEBAR-FOOTER-AND-SPACE-MENU amendment
/// 2): the current profile's initial in a `SidebarStyle.avatarDiameter`
/// circle, centered on the rows' glyph column, then a small chevron that
/// says a click opens a menu. It draws inside a `SidebarItemRowView`, which
/// owns the hover pill, the click and accessibility.
final class SidebarAvatarView: NSView {
    var avatar: SidebarAvatar? { didSet { if avatar != oldValue { needsDisplay = true } } }
    /// Full strength under the pointer or keyboard focus, secondary at rest
    /// (the same rule as the sidebar's other icon items).
    var isStrong = false { didSet { if isStrong != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The circle, in this view's coordinates: centered `bounds.height / 2`
    /// from the leading edge (a square item's center), so it sits on the
    /// glyph column the icon line places the first item on.
    var circleFrame: NSRect {
        let d = SidebarStyle.avatarDiameter
        let center = bounds.height / 2
        return NSRect(x: center - d / 2, y: (bounds.height - d) / 2, width: d, height: d)
    }

    /// The chevron's box: right after the circle.
    var chevronFrame: NSRect {
        let size = SidebarStyle.avatarChevronSize
        return NSRect(x: circleFrame.maxX + SidebarStyle.avatarChevronGap, y: (bounds.height - size) / 2, width: size, height: size)
    }

    /// The avatar's picture, decoded; nil draws the initial.
    static func picture(_ avatar: SidebarAvatar?) -> NSImage? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let avatar else { return }
        performWithTheme {
            let circle = circleFrame
            let colored = avatar.color != nil
            let fill = avatar.color.map { SidebarStyle.color($0) } ?? Palette.textPrimary.withAlphaComponent(isStrong ? 0.24 : 0.16)
            fill.setFill()
            NSBezierPath(ovalIn: circle).fill()
            let text = colored ? Palette.textOnPrimary : (isStrong ? Palette.textPrimary : Palette.textSecondary)
            let font = NSFont.systemFont(ofSize: SidebarStyle.avatarDiameter * 0.56, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: text]
            let size = avatar.initial.size(withAttributes: attributes)
            avatar.initial.draw(at: NSPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2), withAttributes: attributes)
            drawChevron(tint: isStrong ? Palette.textPrimary : Palette.textSecondary)
        }
    }

    // theme-scoped: called only from draw(_:) inside performWithTheme
    private func drawChevron(tint: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: SidebarStyle.avatarChevronSize, weight: .semibold)
        guard let image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let tinted = image.tinted(tint)
        let box = chevronFrame
        let size = tinted.size
        tinted.draw(in: NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height))
    }
}
