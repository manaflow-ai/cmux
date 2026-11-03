import CmuxTheme
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CoreGraphics
import Testing

/// Lawrence 2026-11-03 (msg 19857, screenshot "What's new in nightly 4160614"): "everything's size
/// [must be] proportional [to] the compactness of [the] ui ... cohesive, and derived". The update
/// card's highlights popover drew the pages' own type (13 px body, 18 px lines, 340 px wide) and was
/// then zoomed by the content scale (`app.uiScale` 1.15), so beside 12 pt Compact rows it read at
/// ~15 pt: about a quarter larger than the rows and the card it opens from. Its sizes now derive from
/// the same row tokens as the rows and the card (``SidebarRowTokens``), in page px divided by the
/// page zoom, so it draws the rows' point sizes at any zoom and grows and shrinks with
/// `sidebar.density` and `sidebar.textSize`.
@Suite struct SidebarPopoverMetricsTests {
    /// The app's compact tokens, as in ``SidebarCardMetricsTests``.
    static let base = SidebarRowTokens.Base(rowHeight: 24, space1: 2, space2: 4, space3: 6, space4: 8,
                                            cornerRadius: 6, body: 12, caption: 10.5)

    static func popover(_ density: SidebarDensity, _ text: SidebarTextSize = .standard) -> SidebarPopoverMetrics {
        SidebarRowTokens(density: density, textSize: text, base: base).popover
    }

    /// Compact: the popover's change titles are the rows' titles, its second lines the rows' details.
    @Test func compactPopoverTextIsTheRowsText() {
        let rows = SidebarRowTokens(density: .compact, textSize: .standard, base: Self.base)
        let pop = Self.popover(.compact)
        #expect(pop.bodySize == rows.titleSize)
        #expect(pop.detailSize == rows.captionSize)
        #expect(pop.bodySize == rows.card.titleSize)
        #expect(pop == SidebarPopoverMetrics(width: 312, paddingX: 12, paddingY: 8, bodySize: 12, bodyLine: 17,
                                             detailSize: 10.5, detailLine: 14, itemPaddingY: 4, numberColumn: 12,
                                             columnGap: 6, blockGap: 6, mediaRadius: 6))
    }

    /// The popover's width follows its text: 26 body sizes, on the 2 pt grid (340 pt at 13 pt, the width
    /// it had at 13 pt, 338 now, keeps the measure of about 50 characters a line at every size).
    @Test func widthFollowsTextSize() {
        #expect(Self.popover(.compact).width == 312)
        #expect(Self.popover(.compact, .large).width == 338)
        #expect(Self.popover(.compact, .larger).width == 364)
    }

    /// Comfortable takes the comfortable rows' room, as the card does: more padding and air per change.
    @Test func comfortableIsRoomierNotBigger() {
        let compact = Self.popover(.compact)
        let comfortable = Self.popover(.comfortable)
        #expect(comfortable.bodySize == compact.bodySize)
        #expect(comfortable.paddingX > compact.paddingX)
        #expect(comfortable.paddingY > compact.paddingY)
        #expect(comfortable.itemPaddingY > compact.itemPaddingY)
        #expect(Self.popover(.expanded) == compact)
    }

    /// Every derived size grows monotonically with `sidebar.textSize`, and every line is at least
    /// as tall as its text and on whole points.
    @Test(arguments: SidebarDensity.allCases)
    func everyStepIsMonotonicAndWhole(density: SidebarDensity) {
        let steps = SidebarTextSize.allCases.map { Self.popover(density, $0) }
        for (small, big) in zip(steps, steps.dropFirst()) {
            #expect(big.bodySize > small.bodySize)
            #expect(big.detailSize > small.detailSize)
            #expect(big.bodyLine > small.bodyLine)
            #expect(big.width > small.width)
        }
        for pop in steps {
            #expect(pop.bodyLine >= pop.bodySize && pop.bodyLine == pop.bodyLine.rounded())
            #expect(pop.detailLine >= pop.detailSize && pop.detailLine == pop.detailLine.rounded())
            #expect(pop.detailSize < pop.bodySize)
        }
    }

    /// The page is zoomed by the content scale: a CSS px is `pageZoom` points, so the variables are the
    /// points divided by it. At the 1.15 zoom of the screenshot the body is 12 pt on screen, not 15.
    @Test func cssVariablesUndoThePageZoom() {
        let pop = Self.popover(.compact)
        let one = pop.cssVariables(pageZoom: 1)
        #expect(one["--cmux-sidebar-pop-width"] == "312px")
        #expect(one["--cmux-sidebar-pop-body"] == "12px")
        #expect(one["--cmux-sidebar-pop-detail"] == "10.5px")
        #expect(one["--cmux-sidebar-pop-body-line"] == "17px")
        let zoomed = pop.cssVariables(pageZoom: 1.15)
        #expect(zoomed["--cmux-sidebar-pop-body"] == "10.43px")
        #expect(zoomed["--cmux-sidebar-pop-width"] == "271.3px")
        #expect(Set(one.keys) == Set(SidebarPopoverMetrics.cssKeys))
    }

    /// Every page's theme carries them, so the popover follows a density or text size change live.
    @MainActor @Test func everyPageThemeCarriesThePopoverVariables() {
        let input = ThemeInput(background: ThemeRGB(hex: 0x101018), foreground: ThemeRGB(hex: 0xE8E8F0))
        let theme = WebTheme(ThemeTokens.derive(from: input))
        for key in SidebarPopoverMetrics.cssKeys { #expect(theme.variables[key] != nil, "\(key)") }
    }
}
