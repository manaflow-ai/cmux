import AppKit
import CmuxNextDesign
import CmuxTheme
@testable import CmuxNextPalette
import Testing

/// The scope chips at the start of the search field ("Scopes", "Keyboard Shortcuts", "Search",
/// "Chats & agents") are readable: text and icon reach WCAG AA 4.5:1 on what is behind them, in
/// light and dark themes, with and without Increase Contrast (Lawrence 2026-10-20, of the
/// "Scopes" chip: "It's not very visible to me at all"). The chip under the top one is a back
/// button, not a disabled control, so it is outlined instead of washed out.
@Suite
struct PaletteScopeChipContrastTests {
    static let themes = [
        ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x000000)),
        ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x24292F)),
        ThemeInput(background: ThemeRGB(hex: 0xFDF6E3), foreground: ThemeRGB(hex: 0x657B83)),
        ThemeInput(background: ThemeRGB(hex: 0xEEEEEE), foreground: ThemeRGB(hex: 0x333333)),
        ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xD4D4D4)),
        ThemeInput(background: ThemeRGB(hex: 0x282A36), foreground: ThemeRGB(hex: 0xF8F8F2)),
        ThemeInput(background: ThemeRGB(hex: 0x002B36), foreground: ThemeRGB(hex: 0x839496)),
        ThemeInput(background: ThemeRGB(hex: 0x2B1650), foreground: ThemeRGB(hex: 0xF4E3FF)),
    ]

    static func color(_ tone: PaletteTone, _ tokens: ThemeTokens) -> ThemeRGB {
        switch tone {
        case .primary: tokens.textPrimary
        case .secondary: tokens.textSecondary
        case .tertiary: tokens.textTertiary
        }
    }

    /// The chip's fill over each surface the panel can show: its opaque popup surface (Reduce
    /// Transparency) and the window background (glass at its clearest).
    static func backgrounds(_ ink: PaletteScopeChipInk, _ tokens: ThemeTokens) -> [ThemeRGB] {
        let panels = [tokens.opaqueOverlayFill(lift: ChromeTunables.opaqueOverlayLift.value), tokens.windowBackground.withAlpha(1)]
        return panels.map { panel in
            switch ink.fill {
            case .none: panel
            case .selection: tokens.selectionFill.composited(over: panel)
            case .halfSelection: tokens.selectionFill.withAlpha(tokens.selectionFill.alpha * 0.5).composited(over: panel)
            }
        }
    }

    @Test(arguments: [true, false], [true, false])
    func everyChipIsReadable(isTop: Bool, increaseContrast: Bool) {
        let ink = PaletteScopeChipInk.ink(isTop: isTop, increaseContrast: increaseContrast)
        for input in Self.themes {
            let tokens = ThemeTokens.derive(from: input)
            for background in Self.backgrounds(ink, tokens) {
                let text = Self.color(ink.text, tokens).withAlpha(1).contrast(with: background)
                let icon = Self.color(ink.icon, tokens).withAlpha(1).contrast(with: background)
                #expect(text >= ThemeTokens.minimumTextContrast, "\(input.background) top=\(isTop) text \(text)")
                #expect(icon >= ThemeTokens.minimumTextContrast, "\(input.background) top=\(isTop) icon \(icon)")
            }
        }
    }

    /// The back chip reads as a button you can press: outlined, never a half-strength fill.
    @Test func theBackChipIsOutlinedNotWashedOut() {
        for increaseContrast in [false, true] {
            let back = PaletteScopeChipInk.ink(isTop: false, increaseContrast: increaseContrast)
            #expect(back.outlined)
            #expect(back.fill != .halfSelection)
            #expect(back != PaletteScopeChipInk.ink(isTop: true, increaseContrast: increaseContrast), "top and back look different")
        }
    }

    /// Increase Contrast makes the text primary on every chip.
    @Test func increaseContrastUsesPrimaryText() {
        #expect(PaletteScopeChipInk.ink(isTop: false, increaseContrast: true).text == .primary)
        #expect(PaletteScopeChipInk.ink(isTop: true, increaseContrast: true).text == .primary)
    }
}
