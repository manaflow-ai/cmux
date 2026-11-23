import AppKit
@testable import CmuxNextDesign
import CmuxTheme
import Testing

/// Leo 2026-11-06, on an orange group above rows with blue unread dots: "the blue and the red that we have, like
/// they're clashing"; "these are ugly-ass colors, bro. These are frumpy"; "you can have just... No color group, you
/// know, just pure glass ... the grayscale thing ... your app theme ... your desktop wallpaper ... vibrant nice
/// colors"; "and of course, like the automatic group colors". The palettes and the color a new group takes.
@MainActor struct GroupPaletteTests {
    static func tokens(dark: Bool) -> ThemeTokens {
        let palette: [UInt32] = dark
            ? [0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE]
            : [0x5C5F77, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xACB0BE]
        let input = ThemeInput(background: ThemeRGB(hex: dark ? 0x1E1E2E : 0xEFF1F5), foreground: ThemeRGB(hex: dark ? 0xCDD6F4 : 0x4C4F69),
                               palette: palette.map { ThemeRGB(hex: $0) })
        let scope = ThemeScope(level: .room)
        if let spec = ThemeSpec(dark ? "Palette Dark" : "Palette Light") { scope.setOverride(spec, input: input, animated: false) }
        return scope.tokens
    }

    static func hue(_ rgb: ThemeRGB) -> CGFloat {
        NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1).hueComponent * 360
    }

    static func hueDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    @Test func glassColorsNoNewGroupAndDrawsVibrant() {
        #expect(!GroupPalette.glass.colorsNewGroups)
        for palette in GroupPalette.allCases where palette != .glass { #expect(palette.colorsNewGroups, "\(palette)") }
        let tokens = Self.tokens(dark: true)
        for color in GroupColor.allCases {
            #expect(color.paletteRGB(.glass, tokens: tokens, wallpaper: nil) == color.paletteRGB(.vibrant, tokens: tokens, wallpaper: nil))
        }
    }

    /// Groups made one after another take every color once, each far in hue from the last, before any repeats; never
    /// blue (the unread dot's) or grey.
    @Test func newGroupsTakeTheLeastUsedColorInAnOrderThatKeepsNeighborsApart() {
        var existing: [GroupTint] = []
        for _ in 0 ..< GroupColor.paletteOrder.count { existing.append(.palette(GroupColor.automatic(existing: existing))) }
        #expect(existing == GroupColor.paletteOrder.map { .palette($0) })
        #expect(!GroupColor.paletteOrder.contains(.blue) && !GroupColor.paletteOrder.contains(.grey))
        // A color a person picked counts as used; custom and no color count for none.
        #expect(GroupColor.automatic(existing: [.palette(.purple), .custom(ThemeRGB(hex: 0x336699)), .none]) == .orange)
        #expect(GroupColor.automatic(existing: GroupColor.paletteOrder.map { .palette($0) } + [.palette(.purple)]) == .orange)
        // Next to each other in the order, two vibrant colors are at least 60 degrees apart in hue.
        let tokens = Self.tokens(dark: true)
        for (a, b) in zip(GroupColor.paletteOrder, GroupColor.paletteOrder.dropFirst()) {
            let distance = Self.hueDistance(Self.hue(a.swatchRGB(tokens)), Self.hue(b.swatchRGB(tokens)))
            #expect(distance >= 60, "\(a) then \(b): \(distance) degrees apart")
        }
    }

    /// Vibrant reads as color on dark glass: bright, never the brown or olive of a dark warm hue.
    @Test(arguments: [true, false])
    func vibrantIsBrightAndSaturated(_ dark: Bool) {
        let tokens = Self.tokens(dark: dark)
        for color in GroupColor.allCases where color != .grey {
            let ns = color.swatchRGB(tokens).nsColor.usingColorSpace(.sRGB) ?? .black
            #expect(ns.saturationComponent >= 0.45, "\(color) is washed out: \(ns.saturationComponent)")
            #expect(ns.brightnessComponent >= (dark ? 0.75 : 0.65), "\(color) is dark: \(ns.brightnessComponent)")
        }
    }

    @Test(arguments: [true, false])
    func grayscaleHasNoHueAndEachNeighborDiffersInLightness(_ dark: Bool) {
        let tokens = Self.tokens(dark: dark)
        let greys = GroupColor.paletteOrder.map { $0.paletteRGB(.grayscale, tokens: tokens, wallpaper: nil) }
        for grey in greys {
            // A grey: its channels within 0.08 of each other (a little warm or cool, no hue).
            let spread = max(grey.red, grey.green, grey.blue) - min(grey.red, grey.green, grey.blue)
            #expect(spread <= 0.08, "\(grey) is not a grey: its channels \(spread) apart")
        }
        for (a, b) in zip(greys, greys.dropFirst()) { #expect(a.contrast(with: b) >= 1.25, "\(a) next to \(b)") }
    }

    @Test func theThemePaletteIsTheThemesTerminalColors() {
        let tokens = Self.tokens(dark: true)
        for color in GroupColor.paletteOrder {
            #expect(color.paletteRGB(.theme, tokens: tokens, wallpaper: nil) == color.themeRGB(tokens))
        }
    }

    /// The wallpaper palette follows the desktop picture's hue; a grey picture gives grayscale; no picture yet, vibrant.
    @Test func theWallpaperPaletteFollowsThePicturesHue() {
        let tokens = Self.tokens(dark: true)
        let orange = WallpaperTint(red: 0.71, green: 0.39, blue: 0.24)
        let teal = WallpaperTint(red: 0.1, green: 0.5, blue: 0.55)
        let fromOrange = Self.hue(GroupColor.orange.paletteRGB(.wallpaper, tokens: tokens, wallpaper: orange))
        let fromTeal = Self.hue(GroupColor.orange.paletteRGB(.wallpaper, tokens: tokens, wallpaper: teal))
        #expect(Self.hueDistance(fromOrange, Self.hue(ThemeRGB(red: 0.71, green: 0.39, blue: 0.24))) <= 20)
        #expect(Self.hueDistance(fromOrange, fromTeal) >= 90, "the palette did not move with the picture")
        let grey = WallpaperTint(red: 0.5, green: 0.5, blue: 0.5)
        #expect(GroupColor.red.paletteRGB(.wallpaper, tokens: tokens, wallpaper: grey) == GroupColor.red.paletteRGB(.grayscale, tokens: tokens, wallpaper: nil))
        #expect(GroupColor.red.paletteRGB(.wallpaper, tokens: tokens, wallpaper: nil) == GroupColor.red.paletteRGB(.vibrant, tokens: tokens, wallpaper: nil))
    }

    /// The marble blends a palette's colors; each palette's differs.
    @Test func eachPalettesMarbleHasItsOwnColors() {
        let tokens = Self.tokens(dark: true), wallpaper = WallpaperTint(red: 0.2, green: 0.35, blue: 0.6)
        let marbles = [GroupPalette.theme, .wallpaper, .grayscale, .vibrant].map { GroupColor.marble($0, tokens: tokens, wallpaper: wallpaper) }
        #expect(marbles.allSatisfy { $0.count == 8 })
        #expect(Set(marbles.map { $0.map(\.description) }).count == marbles.count)
    }
}
