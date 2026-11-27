public import AppKit
public import CmuxTheme
public import CmuxNextDesignTokens

/// A group color token drawn from a group palette (`sidebar.groupPalette`, ``GroupPalette``), and the color a new
/// group takes from it.
extension GroupColor {
    /// The order new groups take their colors, each far in hue from the one before, so groups made one after
    /// another never sit in two near colors. No grey and no blue: an app-picked blue would read as the unread dot
    /// beside it (Leo 2026-11-06, an orange group over blue dots: "These colors aren't complementary").
    nonisolated public static let paletteOrder: [GroupColor] = [.purple, .orange, .cyan, .red, .green, .pink, .yellow]

    /// The color a new group takes: of ``paletteOrder``, the one the fewest `existing` groups have, the earlier on a
    /// tie. A custom color or no color counts for none.
    /// - Parameter existing: The colors of the groups there are now.
    public nonisolated static func automatic(existing: [GroupTint]) -> GroupColor {
        var counts: [GroupColor: Int] = [:]
        for case let .palette(token) in existing { counts[token, default: 0] += 1 }
        return paletteOrder.min { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? .purple
    }

    /// The token's color in `palette`, in `tokens`' light or dark variant.
    /// - Parameters:
    ///   - palette: The palette (glass draws vibrant).
    ///   - tokens: The theme the sidebar draws in.
    ///   - wallpaper: The desktop picture's color; nil draws the wallpaper palette as vibrant.
    ///   - gradient: The gradient palette's gradient. A sidebar group under it takes the color at its place in the list
    ///     (the sidebar's drawn tints); a token drawn on its own takes its place in ``paletteOrder``.
    /// - Returns: The color for lines, dots and tinted glass.
    nonisolated public func paletteRGB(_ palette: GroupPalette, tokens: ThemeTokens, wallpaper: WallpaperTint?,
                                       gradient: GroupGradient = .sunset) -> ThemeRGB {
        // Vibrant is tuned for glass as it is; a derived palette is held to a mark's contrast over the sidebar.
        let color: ThemeRGB
        switch palette.drawn {
        case .glass, .vibrant: return swatchRGB(tokens)
        case .theme: color = themeRGB(tokens) ?? swatchRGB(tokens)
        case .grayscale: color = grayscaleRGB(dark: tokens.isDark)
        // A token drawn on its own under the pictorial palette (no place in a list) takes the wallpaper palette's color.
        case .wallpaper, .pictorial: color = wallpaper.flatMap { wallpaperRGB($0, dark: tokens.isDark) } ?? swatchRGB(tokens)
        case .gradient:
            let order = Self.paletteOrder + [.blue, .grey]
            color = gradient.rgb(at: GroupGradient.place(order.firstIndex(of: self) ?? 0, of: order.count))
        }
        return ThemeTokens.readable(color.withAlpha(1), over: tokens.sidebarBackground, minimum: ThemeTokens.minimumMarkContrast)
    }

    /// The palette's eight colors in ``paletteOrder`` then blue: what its marble in the group editor blends. The
    /// gradient palette's are eight steps down its gradient.
    nonisolated public static func marble(_ palette: GroupPalette, tokens: ThemeTokens, wallpaper: WallpaperTint?,
                                          gradient: GroupGradient = .sunset) -> [ThemeRGB] {
        if palette == .pictorial, let bands = wallpaper?.bands, !bands.isEmpty {
            return (0 ..< 8).map { step in
                ThemeTokens.readable(pictorialRGB(bands, at: GroupGradient.place(step, of: 8)), over: tokens.sidebarBackground,
                                     minimum: ThemeTokens.minimumMarkContrast)
            }
        }
        guard palette != .gradient else {
            return (0 ..< 8).map { step in
                ThemeTokens.readable(gradient.rgb(at: GroupGradient.place(step, of: 8)), over: tokens.sidebarBackground,
                                     minimum: ThemeTokens.minimumMarkContrast)
            }
        }
        return (paletteOrder + [.blue]).map { $0.paletteRGB(palette, tokens: tokens, wallpaper: wallpaper) }
    }

    /// Grayscale: eight greys, a little warm or cool, assigned so that ``paletteOrder`` steps light, dark, light.
    nonisolated func grayscaleRGB(dark: Bool) -> ThemeRGB {
        let hex: UInt32 = switch self {
        case .purple: dark ? 0xE6E4E0 : 0xA6A4A0
        case .orange: dark ? 0x827874 : 0x615754
        case .cyan: dark ? 0xBCBDC4 : 0x88898F
        case .red: dark ? 0x8A7A76 : 0x665856
        case .green: dark ? 0xC9CFCB : 0x939A95
        case .pink: dark ? 0x857A82 : 0x63585F
        case .yellow: dark ? 0xD7CFC9 : 0x9D9590
        case .blue: dark ? 0x8B9C9D : 0x627273
        case .grey: dark ? 0xA1A1AA : 0x8E8E93
        }
        return ThemeRGB(hex: hex)
    }

    /// Wallpaper: hues around the desktop picture's, its neighbors for the warm tokens and its complement's for the
    /// cool ones, at one saturation and brightness. A grey picture has no hue to follow: its palette is grayscale.
    nonisolated func wallpaperRGB(_ wallpaper: WallpaperTint, dark: Bool) -> ThemeRGB? {
        let picture = NSColor(srgbRed: wallpaper.red, green: wallpaper.green, blue: wallpaper.blue, alpha: 1)
        guard picture.saturationComponent >= 0.08 else { return grayscaleRGB(dark: dark) }
        let offset: CGFloat = switch self {
        case .red: -30
        case .orange: -10
        case .yellow: 15
        case .green: 40
        case .cyan: 160
        case .blue: 190
        case .purple: 215
        case .pink: -55
        case .grey: 0
        }
        let hue = (picture.hueComponent * 360 + offset + 360).truncatingRemainder(dividingBy: 360) / 360
        let saturation: CGFloat = self == .grey ? 0.08 : dark ? 0.5 : 0.62
        guard let color = NSColor(hue: hue, saturation: saturation, brightness: dark ? 0.95 : 0.78, alpha: 1).usingColorSpace(.sRGB)
        else { return nil }
        return ThemeRGB(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
    }

    /// The pictorial palette's color at `place` (0 the top of the picture, 1 the bottom): the band there, its hue kept,
    /// lifted to the lightness and chroma group colors draw at, so a dark or dull stretch of the picture still reads as
    /// that stretch's color. A band with almost no color stays a grey.
    /// - Parameters:
    ///   - bands: The picture's bands, top first (`WallpaperTint.bands`).
    ///   - place: Where the group sits in the list, 0...1.
    nonisolated public static func pictorialRGB(_ bands: [WallpaperTint], at place: Double) -> ThemeRGB {
        guard !bands.isEmpty else { return .white }
        let band = bands[min(Int((min(max(place, 0), 1) * Double(bands.count)).rounded(.down)), bands.count - 1)]
        let lch = ThemeRGB(red: band.red, green: band.green, blue: band.blue).oklch
        let chroma = lch.chroma < 0.02 ? lch.chroma : min(max(lch.chroma * 1.4, 0.08), 0.18)
        return ThemeRGB(oklchLightness: 0.72, chroma: chroma, hue: lch.hue)
    }
}
