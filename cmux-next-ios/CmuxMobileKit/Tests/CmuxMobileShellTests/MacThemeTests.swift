import CmuxTheme
import Foundation
import Testing
@testable import CmuxMobileDesign

#if os(iOS)
import UIKit

/// ask-87d30da8e5: the phone's chrome takes the Mac's theme and wallpaper. The palette is derived
/// from the theme the Mac sends with the Mac's own code, kept on disk so launch and offline paint
/// it before any link, replaced by what a connected Mac sends, and never overrides a look the
/// person chose on the phone (Match Mac theme off, an accent picked, an explicit Light or Dark).
@Suite struct MacThemeTests {
    static func defaults() -> UserDefaults {
        let name = "MacThemeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    static func cache() -> CmuxMobileMacAppearanceCache {
        CmuxMobileMacAppearanceCache(folder: FileManager.default.temporaryDirectory
            .appendingPathComponent("MacThemeTests-\(UUID().uuidString)", isDirectory: true))
    }

    /// A Catppuccin Mocha-like dark theme.
    static let mocha = CmuxMobileMacAppearance(theme: .init(
        background: "#1e1e2e", foreground: "#cdd6f4",
        palette: ["#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
                  "#585b70", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8"]))
    /// A Solarized Light-like light theme with the Mac's accent set to blue.
    static let solarizedLight = CmuxMobileMacAppearance(theme: .init(
        background: "#fdf6e3", foreground: "#657b83",
        palette: ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5"],
        accent: "blue"))

    static func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    static func contrast(_ a: CmuxMobileRGBA, _ b: CmuxMobileRGBA) -> Double {
        let over = { (c: CmuxMobileRGBA) in ThemeRGB(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha).composited(over: ThemeRGB(red: b.red, green: b.green, blue: b.blue)) }
        return over(a).contrast(with: ThemeRGB(red: b.red, green: b.green, blue: b.blue))
    }

    @Test func thePaletteIsDerivedFromTheMacsTheme() throws {
        let dark = try #require(CmuxMobileMacPalette(Self.mocha))
        #expect(dark.isDark)
        #expect(dark.bg == CmuxMobileRGBA(hex: "#1e1e2e"))
        #expect(dark.terminalBackground == "#1e1e2e")
        #expect(dark.terminalPalette.count == 16)
        #expect(dark.terminalConfigLines.contains("palette = 1=#f38ba8"))
        // The Mac's own derivation: the same tokens the Mac's chrome paints.
        let tokens = ThemeTokens.derive(from: try #require(Self.mocha.input))
        #expect(dark.label == CmuxMobileRGBA(red: tokens.textPrimary.red, green: tokens.textPrimary.green, blue: tokens.textPrimary.blue, alpha: tokens.textPrimary.alpha))
        let light = try #require(CmuxMobileMacPalette(Self.solarizedLight))
        #expect(!light.isDark)
        // The Mac's `appearance.accent` blue gives a hued accent; Mocha's neutral one is its text.
        #expect(light.accent != light.label)
        for palette in [dark, light] {
            #expect(Self.contrast(palette.label, palette.bg) >= 4.5)
            #expect(Self.contrast(palette.label2, palette.bg) >= 4.5)
            #expect(Self.contrast(palette.label3, palette.bg) >= 3)
            #expect(Self.contrast(palette.onAccent, palette.accent) >= 4.5)
        }
    }

    @Test func theWireFrameDecodesAndABadOneDoesNot() throws {
        let frame = ##"{"theme":{"background":"#1e1e2e","foreground":"#cdd6f4","palette":["#000000","#111111","#222222","#333333","#444444","#555555","#666666","#777777"],"accent":"magenta","background_opacity":0.9,"selection_background":"#585b70"},"wallpaper":{"id":"ab12","bytes":3,"tint_opacity":0.62}}"##
        let appearance = try #require(CmuxMobileMacAppearance.decode(Data(frame.utf8)))
        #expect(appearance.theme.accent == "magenta")
        #expect(appearance.theme.selectionBackground == "#585b70")
        #expect(appearance.wallpaper == .init(id: "ab12", bytes: 3, tintOpacity: 0.62))
        #expect(CmuxMobileMacAppearance.decode(Data(##"{"theme":{"background":"red","foreground":"#ffffff","palette":[],"accent":"neutral","background_opacity":1},"wallpaper":null}"##.utf8)) == nil)
    }

    /// Launch and offline: the last theme and wallpaper are read from disk before any link.
    @Test func theCacheIsReadBeforeAnyLink() throws {
        let cache = Self.cache()
        let bytes = Self.png()
        var appearance = Self.mocha
        appearance.wallpaper = .init(id: "a1b2", bytes: bytes.count, tintOpacity: 0.6)
        CmuxMobileMacTheme(defaults: Self.defaults(), cache: cache).apply(appearance, wallpaper: bytes)
        // The next launch, with no Mac reachable.
        let relaunched = CmuxMobileMacTheme(defaults: Self.defaults(), cache: cache)
        #expect(relaunched.appearance == appearance)
        #expect(relaunched.palette == CmuxMobileMacPalette(Self.mocha))
        #expect(relaunched.wallpaper?.tint == 0.6)
        #expect(relaunched.wallpaper?.image != nil)
        #expect(!relaunched.needsWallpaper(appearance))
    }

    /// A connected Mac's theme replaces the cached one, live and on disk.
    @Test func theMacsThemeWinsOverTheCachedOne() throws {
        let cache = Self.cache()
        CmuxMobileMacTheme(defaults: Self.defaults(), cache: cache).apply(Self.mocha)
        let theme = CmuxMobileMacTheme(defaults: Self.defaults(), cache: cache)
        #expect(theme.palette?.isDark == true)
        theme.apply(Self.solarizedLight)
        #expect(theme.palette == CmuxMobileMacPalette(Self.solarizedLight))
        #expect(CmuxMobileMacTheme(defaults: Self.defaults(), cache: cache).palette == CmuxMobileMacPalette(Self.solarizedLight))
        // A frame the phone cannot derive from leaves the last good one.
        var bad = Self.mocha
        bad.theme.foreground = "#12"
        theme.apply(bad)
        #expect(theme.palette == CmuxMobileMacPalette(Self.solarizedLight))
    }

    /// No Mac ever sent a theme: the stock black and white chrome.
    @Test func withNoThemeTheChromeIsTheStockOne() {
        let theme = CmuxMobileMacTheme(defaults: Self.defaults(), cache: Self.cache())
        #expect(theme.matchesMac)
        #expect(theme.palette == nil)
        #expect(theme.wallpaper == nil)
        let stock = CmuxMobileColors.stockBg
        #expect(theme.token(stock) { $0.bg } == stock)
    }

    /// The Mac's color fills only its own appearance's slot: a phone set to the other look keeps it.
    @Test func theMacsColorTakesOnlyItsOwnAppearance() throws {
        let theme = CmuxMobileMacTheme(defaults: Self.defaults(), cache: Self.cache())
        theme.apply(Self.mocha)
        let stock = CmuxMobileColors.stockBg
        let token = theme.token(stock) { $0.bg }
        #expect(token.dark == CmuxMobileRGBA(hex: "#1e1e2e"))
        #expect(token.light == stock.light)
        #expect(theme.interfaceStyle == .dark)
        theme.apply(Self.solarizedLight)
        let light = theme.token(stock) { $0.bg }
        #expect(light.light == CmuxMobileRGBA(hex: "#fdf6e3"))
        #expect(light.dark == stock.dark)
        #expect(theme.interfaceStyle == .light)
    }

    /// Match Mac theme off: the stock chrome, whatever the Mac sent; the choice persists.
    @Test func turningMatchMacOffKeepsTheStockChrome() {
        let store = Self.defaults()
        let cache = Self.cache()
        let theme = CmuxMobileMacTheme(defaults: store, cache: cache)
        theme.apply(Self.mocha)
        theme.matchesMac = false
        #expect(theme.palette == nil)
        #expect(theme.macPalette != nil)
        #expect(theme.interfaceStyle == nil)
        #expect(theme.token(CmuxMobileColors.stockLabel) { $0.label } == CmuxMobileColors.stockLabel)
        #expect(CmuxMobileMacTheme(defaults: store, cache: cache).matchesMac == false)
    }

    /// An install that never chose an accent takes the Mac's; one chosen on the phone wins; Match
    /// Mac goes back to the Mac's.
    @Test func aPhoneAccentWinsOverTheMacs() throws {
        let macTheme = CmuxMobileMacTheme(defaults: Self.defaults(), cache: Self.cache())
        macTheme.apply(Self.solarizedLight)
        let macAccent = try #require(macTheme.palette?.accent)
        let store = Self.defaults()
        let accents = CmuxMobileAccentTheme(defaults: store, macTheme: macTheme)
        #expect(accents.followsMac)
        #expect(accents.accentToken.light == macAccent)
        accents.accent = .red
        #expect(!accents.followsMac)
        #expect(accents.accentToken == CmuxMobileAccent.red.accent)
        #expect(CmuxMobileAccentTheme(defaults: store, macTheme: macTheme).accentToken == CmuxMobileAccent.red.accent)
        accents.matchMac()
        #expect(accents.followsMac)
        #expect(store.string(forKey: CmuxMobileAccentTheme.settingKey) == nil)
        #expect(accents.accentToken.light == macAccent)
        // An explicit Default chosen before this build stays Default.
        store.set("neutral", forKey: CmuxMobileAccentTheme.settingKey)
        #expect(CmuxMobileAccentTheme(defaults: store, macTheme: macTheme).accentToken == CmuxMobileAccent.neutral.accent)
    }
}
#endif
