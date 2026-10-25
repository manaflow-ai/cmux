import CmuxNextDesign
import CmuxTheme
import Testing
import CmuxNextDesignTokens

/// Leo, 2026-10-21: a link opened in a split beside his chat, and Cmd-W closed the chat, because
/// nothing showed which pane had focus. With the default `appearance.focusIndicator` (tabs, no
/// ring) the only cue is the other panes' subtler tabs, so they must read clearly as "not this
/// one", while every tab label stays readable. Later that day the shift on a focus change was
/// "MILDLY jarring ... make the opacity shift not as drastic": the selected tab's pill keeps
/// between half and two thirds of its focused fill.
@Suite struct FocusedPaneTabCueTests {
    static let themes: [ThemeTokens] = [
        ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xD4D4D4))),
        ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0x101018), foreground: ThemeRGB(hex: 0xE8E8F0))),
        ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x24292F))),
        ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0xF5F5F0), foreground: ThemeRGB(hex: 0x333333))),
    ]

    /// The emphasis an unfocused pane's tabs get by default.
    static var unfocused: ChromeEmphasis {
        ChromeEmphasis.forPane(isFocused: false, paneCount: 2, indicator: .tabs,
                               style: FocusIndicatorTunables.inactiveTabStyle.defaultValue,
                               strength: FocusIndicatorTunables.inactiveTabStrength.defaultValue)
    }

    @Test func anUnfocusedPanesSelectedTabIsClearlyNotTheFocusedOne() {
        for tokens in Self.themes {
            let subtle = tokens.emphasized(Self.unfocused)
            #expect(subtle.selectionFill.alpha <= tokens.selectionFill.alpha * 2 / 3 + 0.0001,
                    "the unfocused pill is at most two thirds of the focused one (\(subtle.selectionFill.alpha) of \(tokens.selectionFill.alpha))")
            #expect(subtle.selectionFill.alpha >= tokens.selectionFill.alpha * 0.5 - 0.0001,
                    "the unfocused pill keeps at least half the focused one, so a focus change is no drastic shift")
            let page = tokens.contentBackground.withAlpha(1)
            #expect(subtle.textPrimary.contrast(with: page) < tokens.textPrimary.contrast(with: page) * 0.6,
                    "the unfocused selected label is plainly fainter")
        }
    }

    @Test func unfocusedTabLabelsStayReadable() {
        for tokens in Self.themes {
            let subtle = tokens.emphasized(Self.unfocused)
            let page = tokens.contentBackground.withAlpha(1)
            #expect(subtle.textPrimary.contrast(with: page) >= min(ThemeTokens.subtlePrimaryFloor, tokens.textPrimary.contrast(with: page)) - 0.05)
            #expect(subtle.textSecondary.contrast(with: page) >= min(ThemeTokens.subtleSecondaryFloor, tokens.textSecondary.contrast(with: page)) - 0.05)
        }
    }

    /// The focused pane and a lone pane keep full strength.
    @Test func theFocusedPaneKeepsFullStrength() {
        #expect(ChromeEmphasis.forPane(isFocused: true, paneCount: 2, indicator: .tabs, style: .fade, strength: 0.4) == .full)
        #expect(ChromeEmphasis.forPane(isFocused: false, paneCount: 1, indicator: .tabs, style: .fade, strength: 0.4) == .full)
    }
}
