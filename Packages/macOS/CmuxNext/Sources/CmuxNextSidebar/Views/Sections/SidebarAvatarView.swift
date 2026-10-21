public import AppKit
import CmuxNextDesign

/// The sidebar's profile control (SIDEBAR-FOOTER-AND-SPACE-MENU amendment
/// 2): the current profile's initial (signed in: the cmux user's picture,
/// else their initials) in a `SidebarStyle.avatarDiameter` circle, centered in
/// the square item. The avatar alone opens the menu, as browser profile
/// buttons do. It draws inside a `SidebarItemRowView`, which owns the hover
/// pill, the click and accessibility.
final class SidebarAvatarView: NSView {
    var avatar: SidebarAvatar? { didSet { if avatar != oldValue { needsDisplay = true } } }
    /// Full strength under the pointer or keyboard focus, secondary at rest
    /// (the same rule as the sidebar's other icon items).
    var isStrong = false { didSet { if isStrong != oldValue { needsDisplay = true } } }

    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The circle, in this view's coordinates: centered in the square item,
    /// where the row's hover pill and click area sit.
    var circleFrame: NSRect {
        let d = SidebarStyle.avatarDiameter
        return NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
    }

    /// The avatar's picture, decoded; nil draws the initial.
    static func picture(_ avatar: SidebarAvatar?) -> NSImage? {
        avatar?.imageData.flatMap(NSImage.init(data:)).flatMap { $0.isValid ? $0 : nil }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let avatar else { return }
        performWithTheme { Self.draw(avatar, in: circleFrame, strong: isStrong) }
    }

    /// The picture clipped round, else the initial on the profile's color.
    /// theme-scoped: called from the footer or the menu image renderer.
    static func draw(_ avatar: SidebarAvatar, in circle: NSRect, strong: Bool) {
        if let picture = picture(avatar) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: circle).addClip()
            picture.draw(in: circle, from: .zero, operation: .sourceOver, fraction: strong ? 1 : 0.85, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        let colored = avatar.color != nil
        let fill = avatar.color.map { SidebarStyle.color($0) } ?? Palette.textPrimary.withAlphaComponent(strong ? 0.24 : 0.16)
        fill.setFill()
        NSBezierPath(ovalIn: circle).fill()
        let text = colored ? Palette.textOnPrimary : (strong ? Palette.textPrimary : Palette.textSecondary)
        let scale: CGFloat = avatar.initial.count > 1 ? 0.44 : 0.56
        let font = NSFont.systemFont(ofSize: circle.height * scale, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: text]
        let size = avatar.initial.size(withAttributes: attributes)
        avatar.initial.draw(at: NSPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2), withAttributes: attributes)
    }
}

extension SidebarAvatar {
    /// Render the avatar as the image in the profile menu's current-profile row.
    @MainActor public func image(diameter: Double) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(diameter * 2), pixelsHigh: Int(diameter * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        ThemeScope.app.perform { SidebarAvatarView.draw(self, in: NSRect(origin: .zero, size: size), strong: true) }
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
        return image
    }
}
