import CoreGraphics

/// One optical size for every leading glyph of a sidebar row (a favicon, an app icon, the GitHub mark, a symbol such as
/// the globe, Home's house, a pin). Lawrence 2026-11-09 (screenshot 6:55 PM): the cmux app icon on a row looked
/// smaller than the other icons with a wider gap before its title, and the GitHub mark and the globe drew at different
/// sizes. Each image was fitted by its square, so a picture with a transparent margin drew its ink smaller, and the
/// text column, fixed after the square, left a wider gap after that smaller ink.
///
/// The rule sizes the drawn ink, not the image: the ink's larger side is `target` and its middle sits on `centerY`. A
/// glyph that fills most of the square starts its ink at `leading`; a narrow mark (the pin) centers in the square, so it
/// sits under the house and the other icons instead of on their left edge
/// (https://github.com/manaflow-ai/cmux/issues/42431). Pure, so the rule is tested without views.
nonisolated struct SidebarOpticalGlyph: Equatable, Sendable {
    /// The side of the square every glyph's ink fills along its larger dimension.
    var target: CGFloat
    /// The share of `target` a glyph's ink must span across to start on the column's leading edge; a narrower ink (the
    /// pin, about 0.4) centers in the square. The house and symbols span about 0.9, a square favicon or emoji 1.
    static let fillsColumn: CGFloat = 0.75

    /// The image frame that draws an image of `imageSize` points, whose ink is `ink` in its own coordinates, at the
    /// optical size, its ink starting at `leading` and centered on `centerY`. `ink` has a top-left origin
    /// (`SidebarGlyphInk`); `flipped` says whether the frame's view has one too. `scale` snaps the origin to device
    /// pixels, and the size too, so a bitmap draws crisp (an off-grid size resamples every pixel). Nil for an empty
    /// image or ink.
    func frame(imageSize: CGSize, ink: CGRect, leading: CGFloat, centerY: CGFloat, flipped: Bool, scale: CGFloat) -> CGRect? {
        let longest = max(ink.width, ink.height)
        guard imageSize.width > 0, imageSize.height > 0, longest > 0, target > 0 else { return nil }
        let snap = { (value: CGFloat) in (value * max(1, scale)).rounded() / max(1, scale) }
        // The scale that puts the image's width on the pixel grid, nearest the one that sizes the ink to `target`.
        let k = max(1 / max(1, scale), snap(imageSize.width * target / longest)) / imageSize.width
        // A glyph whose ink fills most of the column (the house, the globe, an app icon, an emoji) starts its ink on
        // `leading`, where text-only titles start (Lawrence 2026-11-09, "not left aligned"). A narrow mark (the pin, its
        // ink well under the column's width) centers in the `target` square instead of hugging the left edge, where its
        // middle sat 3 pt left of theirs (#42431). Centering every glyph would move the house, whose ink is a little
        // taller than wide, 0.5 to 0.65 pt right of the titles' edge.
        let width = ink.width * k
        let x = (width >= target * Self.fillsColumn ? leading : leading + (target - width) / 2) - ink.minX * k
        let y = flipped ? centerY - ink.midY * k : centerY - (imageSize.height - ink.midY) * k
        return CGRect(x: snap(x), y: snap(y), width: imageSize.width * k, height: snap(imageSize.height * k))
    }
}
