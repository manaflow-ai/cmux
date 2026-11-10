import CoreGraphics

/// One optical size for every leading glyph of a sidebar row (a favicon, an app icon, the GitHub mark, a symbol such as
/// the globe, Home's house, a pin). Lawrence 2026-11-09 (screenshot 6:55 PM): the cmux app icon on a row looked
/// smaller than the other icons with a wider gap before its title, and the GitHub mark and the globe drew at different
/// sizes. Each image was fitted by its square, so a picture with a transparent margin drew its ink smaller, and the
/// text column, fixed after the square, left a wider gap after that smaller ink.
///
/// The rule sizes the drawn ink, not the image: the ink's larger side is `target`, its left edge sits at `leading`
/// and its middle on `centerY`. Every glyph then fills the same optical square, ends at the same x, and keeps one gap
/// before the text column at every density. Pure, so the rule is tested without views.
nonisolated struct SidebarOpticalGlyph: Equatable, Sendable {
    /// The side of the square every glyph's ink fills along its larger dimension.
    var target: CGFloat

    /// The image frame that draws an image of `imageSize` points, whose ink is `ink` in its own coordinates, at the
    /// optical size, its ink starting at `leading` and centered on `centerY`. `ink` has a top-left origin
    /// (`SidebarGlyphInk`); `flipped` says whether the frame's view has one too. `scale` snaps the origin to device
    /// pixels. Nil for an empty image or ink.
    func frame(imageSize: CGSize, ink: CGRect, leading: CGFloat, centerY: CGFloat, flipped: Bool, scale: CGFloat) -> CGRect? {
        let longest = max(ink.width, ink.height)
        guard imageSize.width > 0, imageSize.height > 0, longest > 0, target > 0 else { return nil }
        let k = target / longest
        let snap = { (value: CGFloat) in (value * max(1, scale)).rounded() / max(1, scale) }
        let x = leading - ink.minX * k
        let y = flipped ? centerY - ink.midY * k : centerY - (imageSize.height - ink.midY) * k
        return CGRect(x: snap(x), y: snap(y), width: imageSize.width * k, height: imageSize.height * k)
    }
}
