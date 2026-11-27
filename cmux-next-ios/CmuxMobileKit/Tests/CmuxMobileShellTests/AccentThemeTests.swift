import Foundation
import Testing
@testable import CmuxMobileDesign

#if os(iOS)
/// Settings > Appearance > Accent color: the choice persists, Default is the
/// monochrome look (nothing changes for an install that never chose), the
/// names match the desktop's `appearance.accent`, and every accent reads.
@Suite struct AccentThemeTests {
    private func defaults() -> UserDefaults {
        let name = "AccentThemeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultIsMonochrome() {
        let theme = CmuxMobileAccentTheme(defaults: defaults())
        #expect(theme.accent == .neutral)
        #expect(theme.accent.accent == CmuxMobileColorToken(dark: CmuxMobileRGBA(hex: "#FFFFFF"), light: CmuxMobileRGBA(hex: "#000000")))
        #expect(theme.accent.onAccent == CmuxMobileColorToken(dark: CmuxMobileRGBA(hex: "#000000"), light: CmuxMobileRGBA(hex: "#FFFFFF")))
    }

    @Test func choicePersists() {
        let store = defaults()
        CmuxMobileAccentTheme(defaults: store).accent = .blue
        #expect(store.string(forKey: CmuxMobileAccentTheme.settingKey) == "blue")
        #expect(CmuxMobileAccentTheme(defaults: store).accent == .blue)
    }

    @Test func unknownValueFallsBackToDefault() {
        let store = defaults()
        store.set("art", forKey: CmuxMobileAccentTheme.settingKey)
        #expect(CmuxMobileAccentTheme(defaults: store).accent == .neutral)
    }

    /// The desktop's `ThemeAccent` raw values (minus `theme` and `art`, which
    /// need a terminal theme or backdrop art the phone does not have).
    @Test func namesMatchDesktop() {
        let desktop: Set = ["neutral", "theme", "red", "green", "yellow", "blue", "magenta", "cyan"]
        #expect(Set(CmuxMobileAccent.allCases.map(\.rawValue)).isSubset(of: desktop))
        #expect(CmuxMobileAccent.allCases.contains(.blue))
    }

    /// Ink on the fill, and the fill on the plain background, are at least
    /// WCAG AA (4.5:1) in both appearances.
    @Test(arguments: CmuxMobileAccent.allCases) func contrast(_ accent: CmuxMobileAccent) {
        let fill = accent.accent, ink = accent.onAccent
        let black = CmuxMobileRGBA(hex: "#000000"), white = CmuxMobileRGBA(hex: "#FFFFFF")
        #expect(Self.ratio(fill.dark, ink.dark) >= 4.5)
        #expect(Self.ratio(fill.light, ink.light) >= 4.5)
        #expect(Self.ratio(fill.dark, black) >= 4.5)
        #expect(Self.ratio(fill.light, white) >= 4.5)
    }

    private static func ratio(_ a: CmuxMobileRGBA, _ b: CmuxMobileRGBA) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func luminance(_ c: CmuxMobileRGBA) -> Double {
        func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue)
    }
}
#endif
