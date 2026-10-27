public import AppKit
public import CoreGraphics

/// The color of the macOS desktop picture that the window's theme tint leans toward
/// (`appearance.wallpaperTint`), as macOS tints its own window backgrounds with the wallpaper.
///
/// Only the hue comes from the picture: the blend keeps the theme tint's brightness and alpha, so
/// text contrast and the glass's opacity stay what the theme and the Opacity setting give, and a
/// strongly colored theme keeps its own color. ``DesktopWallpaperWatch`` samples the picture.
///
/// ```swift
/// let tint = WallpaperTint(red: 0.2, green: 0.35, blue: 0.6)
/// let color = tint.blended(into: Palette.surfaceBackground)
/// ```
public nonisolated struct WallpaperTint: Equatable, Sendable {
    /// The picture's mean color, sRGB, 0...1.
    public let red: Double
    public let green: Double
    public let blue: Double

    /// How far a neutral theme tint moves toward the picture's hue at that tint's brightness.
    static let strength = 0.5
    /// The most saturation the picture's color brings: a vivid wallpaper tints, never paints.
    static let saturationCap = 0.5
    /// A theme tint this saturated (HSB) or more keeps its color untouched.
    static let themeSaturationLimit = 0.6

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// `theme` leaned toward this color: the picture's hue, at most ``saturationCap`` of its
    /// saturation, at `theme`'s brightness, mixed in by ``strength`` scaled down as `theme` itself
    /// is more saturated. Alpha is kept.
    /// - Parameter theme: The theme tint (`Palette.surfaceBackground`).
    /// - Returns: The tint the window shows.
    public func blended(into theme: NSColor) -> NSColor {
        guard let base = theme.usingColorSpace(.sRGB) else { return theme }
        var themeHue: CGFloat = 0, themeSaturation: CGFloat = 0, themeBrightness: CGFloat = 0, alpha: CGFloat = 0
        base.getHue(&themeHue, saturation: &themeSaturation, brightness: &themeBrightness, alpha: &alpha)
        let amount = Self.strength * max(0, 1 - Double(themeSaturation) / Self.themeSaturationLimit)
        guard amount > 0, let picture = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1).usingColorSpace(.sRGB) else { return theme }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, unused: CGFloat = 0
        picture.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &unused)
        guard let target = NSColor(hue: hue, saturation: min(saturation, Self.saturationCap), brightness: themeBrightness, alpha: 1)
            .usingColorSpace(.sRGB) else { return theme }
        let mix = { (from: CGFloat, to: CGFloat) in from + (to - from) * CGFloat(amount) }
        return NSColor(srgbRed: mix(base.redComponent, target.redComponent), green: mix(base.greenComponent, target.greenComponent),
                       blue: mix(base.blueComponent, target.blueComponent), alpha: alpha)
    }

    /// The tint a window material shows: `theme` leaned toward `wallpaper` when the setting is on,
    /// the window lets the desktop through (not opaque) and shows the desktop rather than other
    /// art (no picture, or the Desktop Wallpaper background); otherwise `theme` as is.
    /// - Parameters:
    ///   - theme: The theme tint.
    ///   - wallpaper: The desktop picture's color; nil before it is sampled or when it can't be.
    ///   - enabled: `appearance.wallpaperTint`.
    ///   - material: The window's material.
    ///   - shown: The art the window draws, nil for none.
    public static func tint(_ theme: NSColor, wallpaper: WallpaperTint?, enabled: Bool, material: WindowMaterial,
                            shown: BackdropSelection?) -> NSColor {
        guard enabled, let wallpaper, material != .opaque, shown == nil || shown == .desktop else { return theme }
        return wallpaper.blended(into: theme)
    }

    /// The mean color of `image`, read from a 16 by 16 copy; nil for an image with no pixels.
    /// - Parameter image: The desktop picture (any size; a small decode is enough).
    public static func average(of image: CGImage) -> WallpaperTint? {
        let side = 16
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        guard image.width > 0, image.height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // The context writes into `bytes` only while the buffer is borrowed.
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var sums = (red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        for pixel in stride(from: 0, to: bytes.count, by: 4) {
            sums.red += Double(bytes[pixel])
            sums.green += Double(bytes[pixel + 1])
            sums.blue += Double(bytes[pixel + 2])
            sums.alpha += Double(bytes[pixel + 3])
        }
        // Premultiplied: dividing by the summed alpha gives the mean of the opaque color.
        guard sums.alpha > 0 else { return nil }
        return WallpaperTint(red: sums.red / sums.alpha, green: sums.green / sums.alpha, blue: sums.blue / sums.alpha)
    }
}
