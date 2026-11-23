import AppKit
import CmuxHomeRender
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextHome
import Testing

/// Leo 2026-11-16: "why is this icon pink lol". A failed send's badge (the disc with "!") and its
/// "Not Delivered" label drew in the theme's ANSI red (`Palette.danger`), which is salmon pink in
/// Soft Blue dark (#F06C63). They are a status mark like the sidebar's error mark, so they draw in
/// `systemRed`'s hue (`Palette.statusError`) in every theme.
@MainActor @Suite struct HomeFailedBadgeSystemRedTests {
    /// Soft Blue dark (Resources/cmux-themes/Soft Blue): ANSI red is #F06C63.
    nonisolated static let softBlueDark = ThemeInput(
        background: ThemeRGB(hex: 0x181818), foreground: ThemeRGB(hex: 0xFFFFFF),
        palette: [0x2F2F2F, 0xF06C63, 0x5FC28A, 0xF0B54A, 0x5A8EE6, 0xB58CF0, 0x4FBFD0, 0xD4D4D4,
                  0x6B6B6B, 0xFF8A80, 0x7ED6A3, 0xF6C770, 0x7AA7F0, 0xC9A6F5, 0x7AD3DF, 0xFFFFFF].map { ThemeRGB(hex: $0) },
        selectionBackground: ThemeRGB(hex: 0x24395A), selectionForeground: ThemeRGB(hex: 0xFFFFFF))

    @Test func failedSendIsSystemRedNotTheThemesANSIRed() {
        let store = ThemeStore()
        let app = ThemeScope(root: store)
        store.apply(Self.softBlueDark)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        app.root(host)
        let tokens = ThemeTokens.derive(from: Self.softBlueDark)
        let systemRed = tokens.statusDot(.error)
        let ansiRed = tokens.danger
        #expect(abs(systemRed.red - ansiRed.red) + abs(systemRed.green - ansiRed.green) > 0.1, "fixture: the theme's red must differ from system red")
        for style in [HomePalette.BubbleStyle.iMessage, .theme] {
            let failure = host.performWithTheme { HomeThemePalette.resolveInScope(active: true, style: style) }.failure
            let drawn = ThemeRGB(red: Double(failure.red), green: Double(failure.green), blue: Double(failure.blue))
            #expect(abs(drawn.red - systemRed.red) < 0.01 && abs(drawn.green - systemRed.green) < 0.01
                && abs(drawn.blue - systemRed.blue) < 0.01,
                "\(style): failed badge \(drawn), want system red \(systemRed) (theme ANSI red is \(ansiRed))")
        }
    }
}
