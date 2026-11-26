import CoreGraphics

/// One optical size for every leading glyph of a sidebar row (a favicon, an app icon, the GitHub mark, a symbol such as
/// the globe, Home's house, a pin). Lawrence 2026-11-09 (screenshot 6:55 PM): the cmux app icon on a row looked
/// smaller than the other icons with a wider gap before its title, and the GitHub mark and the globe drew at different
/// sizes. Each image was fitted by its square, so a picture with a transparent margin drew its ink smaller, and the
/// text column, fixed after the square, left a wider gap after that smaller ink.
///
/// The rule sizes the drawn ink, not the image: the ink's height is `target` (its width for a very wide glyph), it centers in the `target` square
/// starting at `leading`, and its middle sits on `centerY`. Every glyph then shares one center line: a wide glyph fills
/// the square edge to edge, and a tall narrow one (the pin) centers under it, not on its left edge
/// (https://github.com/manaflow-ai/cmux/issues/42431). Pure, so the rule is tested without views.
nonisolated struct SidebarOpticalGlyph: Equatable, Sendable {
    /// The side of the square every glyph's ink fills along its larger dimension.
    var target: CGFloat
    /// The raster box used to prepare tab-sized favicon images before fitting their measured ink.
    var box: CGFloat?

    init(target: CGFloat, box: CGFloat? = nil) {
        self.target = target
        self.box = box
    }

    /// The image frame that draws an image of `imageSize` points, whose ink is `ink` in its own coordinates, at the
    /// optical size, its ink starting at `leading` and centered on `centerY`. `ink` has a top-left origin
    /// (`SidebarGlyphInk`); `flipped` says whether the frame's view has one too. `scale` snaps the origin to device
    /// pixels, and the size too, so a bitmap draws crisp (an off-grid size resamples every pixel). Nil for an empty
    /// image or ink.
    func frame(imageSize: CGSize, ink: CGRect, leading: CGFloat, centerY: CGFloat, flipped: Bool, scale: CGFloat) -> CGRect? {
        let extent = Self.fittedExtent(ink.size)
        guard imageSize.width > 0, imageSize.height > 0, extent > 0, target > 0 else { return nil }
        let snap = { (value: CGFloat) in (value * max(1, scale)).rounded() / max(1, scale) }
        // The scale that puts the image's width on the pixel grid, nearest the one that sizes the ink to `target`.
        let k = max(1 / max(1, scale), snap(imageSize.width * target / extent)) / imageSize.width
        // The ink centers in the square: a glyph wider than tall (fitted by height) spills evenly past both sides, so the
        // pin still centers under Home's house.
        let x = leading + (target - ink.width * k) / 2 - ink.minX * k
        let y = flipped ? centerY - ink.midY * k : centerY - (imageSize.height - ink.midY) * k
        return CGRect(x: snap(x), y: snap(y), width: snap(imageSize.width * k), height: snap(imageSize.height * k))
    }

    /// The ink side the fit holds to `target`: its height, so a wide glyph (Home's house) stands as tall as a tall one
    /// (the App Store's bag) and both read one size (Lucas 2026-11-16: "the home icon should increase in size to match
    /// the app store icon"). A glyph wider than `maxAspect` times its height fits by width instead, so it never spills
    /// far past the icon column.
    static func fittedExtent(_ ink: CGSize) -> CGFloat {
        max(ink.height, ink.width / maxAspect)
    }

    /// The widest ink, as a share of its height, the fit lets stand at full height.
    static let maxAspect: CGFloat = 1.25
}
