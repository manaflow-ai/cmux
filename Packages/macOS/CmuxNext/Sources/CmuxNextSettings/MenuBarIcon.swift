public import AppKit

/// The cmux menu bar icon, the same one cmux-classic shows (user 2026-10-28: "cmux-next menubar logo
/// needs to be same icon as cmux-classic"): the cmux center-mark chevron from
/// `Icon Center Image Artwork.svg`, drawn in an 18 by 18 pt template image at classic's glyph rect,
/// so it has classic's shape and size and follows the menu bar's light, dark and tinted looks.
///
/// Classic draws it in `MenuBarIconRenderer` (`Sources/App/MenuBarExtraController.swift` on `main`);
/// this draws the same path without classic's unread badge. The image draws on demand at each
/// backing scale, so it stays sharp on Retina and non-Retina displays.
///
/// ```swift
/// let extra = MenuBarExtra(registry: registry, icon: MenuBarIcon().image(), host: services)
/// ```
nonisolated public struct MenuBarIcon: Sendable {
    /// The image's size in points: classic's status item bitmap.
    public static let size = NSSize(width: 18, height: 18)
    /// Where the chevron sits in the image (points, origin bottom left): classic's glyph rect.
    static let glyphRect = NSRect(x: 1.2, y: 1.5, width: 11.6, height: 15.0)

    /// Makes the icon value; it holds no state.
    public init() {}

    /// A new template image of the icon (each caller may set its own accessibility label).
    public func image() -> NSImage {
        let image = NSImage(size: Self.size, flipped: false) { _ in
            NSColor.black.setFill()
            chevronPath(in: Self.glyphRect).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The cmux center-mark path from `Icon Center Image Artwork.svg` (its bounds x 384...753,
/// y 255...768, y down), mapped into `rect` (y up).
nonisolated private func chevronPath(in rect: NSRect) -> NSBezierPath {
    let minX: CGFloat = 384, minY: CGFloat = 255, width: CGFloat = 369, height: CGFloat = 513
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: rect.minX + (x - minX) / width * rect.width,
                y: rect.minY + (1 - (y - minY) / height) * rect.height)
    }
    let path = NSBezierPath()
    path.move(to: point(384, 255))
    path.line(to: point(753, 511.5))
    path.line(to: point(384, 768))
    path.line(to: point(384, 654))
    path.line(to: point(582.692, 511.5))
    path.line(to: point(384, 369))
    path.close()
    return path
}
