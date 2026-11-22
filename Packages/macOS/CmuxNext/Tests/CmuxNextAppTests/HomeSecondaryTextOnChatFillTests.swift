import AppKit
import CmuxHomeRender
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextHome
import Testing

/// User 2026-11-03: "we need to make sure every single theme, all the UI elements are colored
/// properly". Home's secondary text (names, times, receipts) was raised to 4.5:1 on the window's
/// colour, but the chat paints its own fill over the window (`appearance.surfaces.home`). The host
/// set that fill after the palette's readability pass, so on a light theme with a dark Home
/// background the grey names and times read at about 2:1. The secondary text reads on the colour
/// the chat really shows: its fill over the window, in both bubble styles.
@MainActor @Suite struct HomeSecondaryTextOnChatFillTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let theme: ThemeInput
        let homeFill: ThemeRGB
        var testDescription: String { name }
    }

    nonisolated static let cases: [Case] = [
        Case(name: "light theme, dark Home background", theme: ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x1F2328)),
             homeFill: ThemeRGB(hex: 0x1C2A4A)),
        Case(name: "dark theme, light Home background", theme: ThemeInput(background: ThemeRGB(hex: 0x191724), foreground: ThemeRGB(hex: 0xE0DEF4)),
             homeFill: ThemeRGB(hex: 0xF2E9E1)),
        Case(name: "dark theme, half-clear mid Home background", theme: ThemeInput(background: ThemeRGB(hex: 0x1E1E2E), foreground: ThemeRGB(hex: 0xCDD6F4)),
             homeFill: ThemeRGB(hex: 0x9CA0B0).withAlpha(0.6)),
    ]

    @Test(arguments: cases)
    func secondaryTextReadsOnTheChatsOwnFill(_ c: Case) {
        let store = ThemeStore()
        let app = ThemeScope(root: store)
        store.apply(c.theme)
        app.setSurfaceBackgrounds(SurfaceBackgrounds(overrides: [.home: SurfaceBackground(color: c.homeFill.withAlpha(1), opacity: c.homeFill.alpha)]))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        app.root(host)
        let window = ThemeTokens.derive(from: c.theme).windowBackground.withAlpha(1)
        for style in [HomePalette.BubbleStyle.iMessage, .theme] {
            let palette = host.performWithTheme { HomeThemePalette.resolveInScope(active: true, style: style) }
            let fill = ThemeRGB(red: Double(palette.background.red), green: Double(palette.background.green),
                                blue: Double(palette.background.blue)).withAlpha(Double(palette.background.alpha))
            let ground = fill.composited(over: window)
            let ink = ThemeRGB(red: Double(palette.secondaryText.red), green: Double(palette.secondaryText.green),
                               blue: Double(palette.secondaryText.blue))
            #expect(ink.contrast(with: ground) >= ThemeTokens.minimumTextContrast - 0.01,
                    "\(style): secondary text \(ink.contrast(with: ground)):1 on the chat's fill")
        }
    }
}
