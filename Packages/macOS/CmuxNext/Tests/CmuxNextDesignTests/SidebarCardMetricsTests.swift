import CmuxTheme
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CoreGraphics
import Testing

/// Lawrence 2026-11-01 (msg 19498): "the card must reflect my compactness level". The sidebar's
/// "Updated to Nightly" card drew its own fixed sizes (12 px padding, 13 px text, a 24 px button,
/// a 12 px corner) at every sidebar density, so at Compact it towered over the 24 pt rows. Its
/// padding, text, button and corner now come from the row tokens of `sidebar.density` and
/// `sidebar.textSize` (``SidebarRowTokens``), the same ones the rows read: at Compact the card is
/// about as tight as a row.
@Suite struct SidebarCardMetricsTests {
    /// The app's compact tokens: 24 pt rows, the 2/4/6/8 pt grid, 6 pt item corners, 12 pt body and
    /// 10.5 pt caption text.
    static let base = SidebarRowTokens.Base(rowHeight: 24, space1: 2, space2: 4, space3: 6, space4: 8,
                                            cornerRadius: 6, body: 12, caption: 10.5)

    static func card(_ density: SidebarDensity, _ text: SidebarTextSize = .standard) -> SidebarCardMetrics {
        SidebarRowTokens(density: density, textSize: text, base: base).card
    }

    @Test func compactIsAsTightAsARow() {
        let rows = SidebarRowTokens(density: .compact, textSize: .standard, base: Self.base)
        #expect(rows.rowHeight == 24)
        #expect(rows.horizontalInset == 6)
        let card = Self.card(.compact)
        #expect(card == SidebarCardMetrics(paddingX: 6, paddingY: 4, gap: 2, cornerRadius: 10, titleSize: 12, noteSize: 10.5,
                                           buttonHeight: 20, buttonPaddingX: 6, buttonRadius: 6, closeSide: 16))
    }

    @Test func comfortableTakesTheComfortableRowsRoom() {
        let rows = SidebarRowTokens(density: .comfortable, textSize: .standard, base: Self.base)
        #expect(rows.rowHeight == 28)
        #expect(rows.horizontalInset == 8)
        #expect(Self.card(.comfortable) == SidebarCardMetrics(paddingX: 8, paddingY: 6, gap: 4, cornerRadius: 12, titleSize: 12,
                                                              noteSize: 10.5, buttonHeight: 24, buttonPaddingX: 8, buttonRadius: 6,
                                                              closeSide: 20))
    }

    /// Expanded keeps the app tokens exactly, as its rows do (SidebarDensityTokens): only the rows grow a line.
    @Test func expandedKeepsCompactsTokens() {
        #expect(Self.card(.expanded) == Self.card(.compact))
    }

    /// `sidebar.textSize` grows the card's text and button with the rows' text and height.
    @Test func textSizeGrowsTextAndButton() {
        let card = Self.card(.compact, .large)
        #expect(card.titleSize == 13)
        #expect(card.noteSize == 11.5)
        #expect(card.buttonHeight == 23)
        #expect(card.paddingY == 4)
    }

    /// The page is zoomed by the interface scale, so a CSS px is `pageZoom` points: the variables
    /// are the points divided by it, and the card draws the rows' sizes at any zoom.
    @Test func cssVariablesAreInPagePixels() {
        let card = Self.card(.compact)
        let one = card.cssVariables(pageZoom: 1)
        #expect(one["--cmux-sidebar-card-padding-x"] == "6px")
        #expect(one["--cmux-sidebar-card-padding-y"] == "4px")
        #expect(one["--cmux-sidebar-card-gap"] == "2px")
        #expect(one["--cmux-sidebar-card-radius"] == "10px")
        #expect(one["--cmux-sidebar-card-title"] == "12px")
        #expect(one["--cmux-sidebar-card-note"] == "10.5px")
        #expect(one["--cmux-sidebar-card-button"] == "20px")
        #expect(one["--cmux-sidebar-card-button-padding-x"] == "6px")
        #expect(one["--cmux-sidebar-card-button-radius"] == "6px")
        #expect(one["--cmux-sidebar-card-close"] == "16px")
        #expect(card.cssVariables(pageZoom: 2)["--cmux-sidebar-card-button"] == "10px")
    }

    /// Every page's theme carries them, so the sidebar's card page follows a density change live.
    @MainActor @Test func everyPageThemeCarriesTheCardVariables() {
        let input = ThemeInput(background: ThemeRGB(hex: 0x101018), foreground: ThemeRGB(hex: 0xE8E8F0))
        let theme = WebTheme(ThemeTokens.derive(from: input))
        for key in SidebarCardMetrics.cssKeys { #expect(theme.variables[key] != nil, "\(key)") }
    }
}
