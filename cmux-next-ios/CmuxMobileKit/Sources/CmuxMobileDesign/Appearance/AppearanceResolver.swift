#if os(iOS)
import CmuxMobileLinkFFI
import Foundation
import SwiftUI
import UIKit

/// Everything the phone draws from one appearance: the palette, the terminal
/// theme, the backdrop and the color scheme, resolved once per change (not per
/// frame) from a ``CmuxMobileAppearanceSnapshot``.
public struct CmuxMobileResolvedAppearance: Sendable, Equatable {
    public var palette: CmuxMobilePaletteValues
    /// The terminal's colors and font for dark and light.
    public var terminal: CmuxMobileTerminalTheme
    /// The backdrop under the chrome; nil draws `bg` alone.
    public var backdrop: CmuxMobileBackdropStyle?
    /// A theme that does not follow the system (`follows_system: false`) holds
    /// its own scheme; nil follows the phone's Light/Dark setting.
    public var colorScheme: ColorScheme?
    /// Sidebar group colors (`sidebar.groupPalette`, `sidebar.groupGradient`).
    public var groupPalette: String
    public var groupGradient: String
    /// The names the Mac gave its themes (Settings shows them).
    public var themeNames: (dark: String?, light: String?)

    public static func == (a: Self, b: Self) -> Bool {
        a.palette == b.palette && a.terminal == b.terminal && a.backdrop == b.backdrop && a.colorScheme == b.colorScheme
            && a.groupPalette == b.groupPalette && a.groupGradient == b.groupGradient
            && a.themeNames.dark == b.themeNames.dark && a.themeNames.light == b.themeNames.light
    }
}

/// One terminal theme pair: what the Ghostty config takes (`background`,
/// `foreground`, `palette`, cursor, selection) and the font family.
public struct CmuxMobileTerminalTheme: Sendable, Equatable {
    public struct Colors: Sendable, Equatable {
        public var background: CmuxMobileRGBA
        public var foreground: CmuxMobileRGBA
        public var palette: [CmuxMobileRGBA]
        public var cursor: CmuxMobileRGBA?
        public var selectionBackground: CmuxMobileRGBA?
        public var selectionForeground: CmuxMobileRGBA?
        public var backgroundOpacity: Double
    }

    public var dark: Colors
    public var light: Colors
    /// The Mac's `terminal.fontFamily` (nil: the phone's own font). The size
    /// stays the phone's setting.
    public var fontFamily: String?

    public func colors(dark isDark: Bool) -> Colors { isDark ? dark : light }

    /// The phone's built-in terminal look: true black, the default foreground.
    public static let neutral: CmuxMobileTerminalTheme = {
        let colors = Colors(background: CmuxMobileRGBA(hex: "#000000"), foreground: CmuxMobileRGBA(hex: "#E6E6E6"),
                            palette: [], cursor: nil, selectionBackground: nil, selectionForeground: nil, backgroundOpacity: 1)
        return CmuxMobileTerminalTheme(dark: colors, light: colors, fontFamily: nil)
    }()
}

/// The backdrop: the Mac's background image, re-cropped and blurred on the
/// phone, then the theme's tint over it (as the Mac's window material:
/// the background at the theme's opacity times `1 - glassTransparency`,
/// hue- and saturation-tuned).
public struct CmuxMobileBackdropStyle: Sendable, Equatable {
    /// The image file (Application Support/appearance/assets/<sha256>.jpg).
    public var imageURL: URL
    public var sha256: String
    public var opacity: Double
    /// Blur radius in the Mac's points (scaled to the phone's screen).
    public var blur: Double
    /// The tint over the image, per scheme (alpha included).
    public var tint: CmuxMobileColorToken
    /// Under the image: the theme's opaque background.
    public var base: CmuxMobileColorToken
}

/// Derives a ``CmuxMobileResolvedAppearance`` from a snapshot with the Mac's
/// own derivation (`cmux-theme-tokens::ThemeTokens::derive` over
/// `CmuxMobileLinkFFI`), so the phone's colors are the Mac's.
public enum CmuxMobileAppearanceResolver {
    /// Contrast minimums (`theme.constants` in the Mac's design tokens).
    static let textMinimum = 4.5
    static let markMinimum = 3.0

    /// `snapshot`'s look; `backgroundURL` is its background image when the
    /// phone holds it (nil: no backdrop yet).
    public static func resolve(_ snapshot: CmuxMobileAppearanceSnapshot, backgroundURL: URL?) -> CmuxMobileResolvedAppearance? {
        guard let theme = snapshot.theme, let darkInput = theme.dark?.input ?? theme.light?.input,
              let lightInput = theme.light?.input ?? theme.dark?.input else { return nil }
        let accent = snapshot.accent ?? "neutral"
        let dark = deriveThemeTokens(input: wire(darkInput, accent: accent))
        let light = deriveThemeTokens(input: wire(lightInput, accent: accent))
        let follows = theme.followsSystem ?? true
        let scheme: ColorScheme? = follows ? nil : (dark.isDark ? .dark : .light)
        let glass = clamp(snapshot.glassTransparency ?? 0, 0, 1)
        let tuning = (hue: clamp(snapshot.hue ?? 0.5, 0, 1), saturation: clamp(snapshot.saturation ?? 1, 0, 2))
        let separateSidebar = snapshot.sidebarSurface == "separate"
            || ["two-tone", "floating", "blocks"].contains(snapshot.chromeStyle ?? "")

        var backdrop: CmuxMobileBackdropStyle?
        if let background = snapshot.background, background.hasValidHash, let url = backgroundURL {
            let tint = { (t: DerivedThemeTokens) -> CmuxMobileRGBA in
                let alpha = clamp(t.backgroundOpacity, 0, 1) * (1 - glass)
                return tuned(rgba(t.windowBackground, alpha: 1), hue: tuning.hue, saturation: tuning.saturation).with(alpha: alpha)
            }
            backdrop = CmuxMobileBackdropStyle(imageURL: url, sha256: background.sha256, opacity: clamp(background.opacity, 0, 1),
                                               blur: max(0, background.blur),
                                               tint: CmuxMobileColorToken(dark: tint(dark), light: tint(light)),
                                               base: CmuxMobileColorToken(dark: rgba(dark.windowBackground, alpha: 1),
                                                                          light: rgba(light.windowBackground, alpha: 1)))
        }

        let pair = { (make: (DerivedThemeTokens) -> CmuxMobileRGBA) in CmuxMobileColorToken(dark: make(dark), light: make(light)) }
        let chat = snapshot.chat
        var palette = CmuxMobilePaletteValues.neutral
        for role in CmuxMobileColorRole.allCases {
            palette[role] = pair { t in color(role, t, chat: chat, separateSidebar: separateSidebar, backdrop: backdrop != nil) }
        }
        let terminal = CmuxMobileTerminalTheme(dark: terminalColors(dark), light: terminalColors(light),
                                               fontFamily: snapshot.terminal?.fontFamily.flatMap { $0.isEmpty ? nil : $0 })
        return CmuxMobileResolvedAppearance(
            palette: palette, terminal: terminal, backdrop: backdrop, colorScheme: scheme,
            groupPalette: snapshot.groups?.palette ?? "glass", groupGradient: snapshot.groups?.gradient ?? "sunset",
            themeNames: (theme.dark?.name, theme.light?.name))
    }

    static func wire(_ input: CmuxMobileAppearanceSnapshot.Input, accent: String) -> ThemeInputWire {
        ThemeInputWire(background: input.background, foreground: input.foreground, palette: input.palette,
                       selectionBackground: input.selectionBackground, selectionForeground: input.selectionForeground,
                       cursor: input.cursor, backgroundOpacity: input.backgroundOpacity, backgroundBlur: Int32(clamping: input.backgroundBlur),
                       accent: accent, accentColor: input.accentColor)
    }

    /// One role's color in one scheme's derived tokens. Every value is a
    /// derived token, a composite of one over the background, or a status
    /// color pushed to its contrast minimum by the Mac's `readable`.
    static func color(_ role: CmuxMobileColorRole, _ t: DerivedThemeTokens, chat: CmuxMobileAppearanceSnapshot.Chat?,
                      separateSidebar: Bool, backdrop: Bool) -> CmuxMobileRGBA {
        let bg = t.windowBackground.opaque
        let over = { (c: ThemeColor) in rgba(composite(c, over: bg)) }
        let readableOn = { (c: ThemeColor, surface: ThemeColor, minimum: Double) in rgba(themeReadable(color: c, surface: surface, minimum: minimum)) }
        let code = composite(t.chromeBackground, over: bg)
        let ansi = { (i: Int) in i < t.ansi.count ? t.ansi[i] : t.textPrimary }
        switch role {
        // The page stays the theme's opaque background even with a picture: the system's
        // navigation and tab containers paint an opaque page under every screen, so a clear
        // page read black (or white). The picture shows where screens leave the page (the
        // sidebar, the sliding card) until those containers are cleared too.
        case .bg, .bgGrouped: return rgba(bg)
        case .surface, .sheet, .card: return rgba(t.overlayFill)
        case .surfaceRaised: return over(t.chromeBackground)
        case .bubble: return chat?.sent.map { CmuxMobileRGBA(hex: $0) } ?? over(t.pressedFill)
        case .onBubble: return chat?.sentText.map { CmuxMobileRGBA(hex: $0) } ?? rgba(t.textPrimary)
        case .codeBg: return rgba(code)
        case .fill: return rgba(t.hoverFill)
        case .fillSelected: return rgba(t.selectionFill)
        case .fillPressed: return rgba(t.pressedFill)
        case .separator: return rgba(t.separator)
        case .label: return rgba(t.textPrimary)
        case .label2, .legal: return rgba(t.textSecondary)
        case .label3, .offline: return rgba(t.textTertiary)
        case .accent: return rgba(t.accent)
        case .onAccent: return rgba(t.onAccent)
        case .success: return rgba(t.success)
        case .danger: return rgba(t.danger)
        case .dangerText: return readableOn(t.danger, bg, textMinimum)
        case .warning, .needsYou: return rgba(t.attention)
        case .diffAddText: return readableOn(ansi(2), code, textMinimum)
        case .diffDelText: return readableOn(ansi(1), code, textMinimum)
        case .diffAddRow: return rgba(ansi(2), alpha: 0.15)
        case .diffDelRow: return rgba(ansi(1), alpha: 0.15)
        case .diffAddWord: return rgba(ansi(2), alpha: 0.40)
        case .diffDelWord: return rgba(ansi(1), alpha: 0.40)
        case .diffAddGutter: return rgba(ansi(2), alpha: 0.30)
        case .diffDelGutter: return rgba(ansi(1), alpha: 0.30)
        case .diffHunkBg: return rgba(t.hoverFill)
        case .syntaxKeyword: return readableOn(ansi(5), code, textMinimum)
        case .syntaxString: return readableOn(ansi(2), code, textMinimum)
        case .syntaxNumber: return readableOn(ansi(3), code, textMinimum)
        case .syntaxType: return readableOn(ansi(6), code, textMinimum)
        case .syntaxFunction: return readableOn(ansi(4), code, textMinimum)
        case .syntaxComment: return rgba(t.textTertiary)
        case .scrim: return rgba(t.shadow)
        case .cardStroke: return rgba(t.paneBorder)
        case .shimmerBand: return rgba(t.hoverFill)
        // Two-tone: the sidebar a shade apart from the main pane (the Mac's
        // separate sidebar surface: its shadow color over the window).
        case .sidebarShade: return separateSidebar ? rgba(t.shadow) : rgba(t.shadow, alpha: 0)
        case .terminalBackground: return rgba(t.terminalBackground.opaque)
        }
    }

    static func terminalColors(_ t: DerivedThemeTokens) -> CmuxMobileTerminalTheme.Colors {
        .init(background: rgba(t.terminalBackground.opaque), foreground: rgba(t.terminalForeground.opaque), palette: t.ansi.map { rgba($0) },
              cursor: t.cursor.map { rgba($0) }, selectionBackground: t.selectionBackground.map { rgba($0) },
              selectionForeground: t.selectionForeground.map { rgba($0) }, backgroundOpacity: t.backgroundOpacity)
    }

    static func rgba(_ c: ThemeColor, alpha: Double? = nil) -> CmuxMobileRGBA {
        CmuxMobileRGBA(red: c.r, green: c.g, blue: c.b, alpha: alpha ?? c.a)
    }

    /// `color` painted over the opaque `base` (`Rgb::composited`).
    static func composite(_ color: ThemeColor, over base: ThemeColor) -> ThemeColor {
        let a = clamp(color.a, 0, 1)
        return ThemeColor(r: base.r + (color.r - base.r) * a, g: base.g + (color.g - base.g) * a, b: base.b + (color.b - base.b) * a, a: 1)
    }

    /// The Mac's backdrop tint tuning (`WindowMaterialView.tunedTint`): hue
    /// shifted by `hue - 0.5` of a turn, saturation scaled.
    static func tuned(_ color: CmuxMobileRGBA, hue: Double, saturation: Double) -> CmuxMobileRGBA {
        guard hue != 0.5 || saturation != 1 else { return color }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        var shifted = (Double(h) + hue - 0.5).truncatingRemainder(dividingBy: 1)
        if shifted < 0 { shifted += 1 }
        let out = UIColor(hue: shifted, saturation: min(max(Double(s) * saturation, 0), 1), brightness: b, alpha: a)
        var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, al: CGFloat = 0
        out.getRed(&r, green: &g, blue: &bl, alpha: &al)
        return CmuxMobileRGBA(red: Double(r), green: Double(g), blue: Double(bl), alpha: Double(al))
    }

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v.isFinite ? min(max(v, lo), hi) : lo }
}

extension ThemeColor {
    var opaque: ThemeColor { ThemeColor(r: r, g: g, b: b, a: 1) }
}

extension CmuxMobileRGBA {
    func with(alpha: Double) -> CmuxMobileRGBA { CmuxMobileRGBA(red: red, green: green, blue: blue, alpha: alpha) }

    /// `#RRGGBB` (alpha dropped).
    public var hex: String {
        let c = { (v: Double) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(red), c(green), c(blue))
    }
}
#endif
