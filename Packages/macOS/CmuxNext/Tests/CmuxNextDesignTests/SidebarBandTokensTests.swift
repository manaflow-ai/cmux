@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CoreGraphics
import Testing

/// Lawrence 2026-11-04: at Expanded the pinned rows and their hover card are at least the Comfortable
/// size (row 28 pt, card 207×187 in the Sidebar States Playground). Expanded keeps the app's one-line
/// row, so the band's rows were 24 pt and the card Compact's 203×167, under 37 pt list rows; pinned rows
/// were too short. The band and the card now read ``SidebarRowTokens/band``.
@Suite struct SidebarBandTokensTests {
    /// The app's compact tokens: 24 pt rows, the 2/4/6/8 pt grid, 6 pt corners, 12/10.5 pt text.
    static let base = SidebarRowTokens.Base(rowHeight: 24, space1: 2, space2: 4, space3: 6, space4: 8,
                                            cornerRadius: 6, body: 12, caption: 10.5)

    static func tokens(_ density: SidebarDensity, _ text: SidebarTextSize = .standard) -> SidebarRowTokens {
        SidebarRowTokens(density: density, textSize: text, base: base)
    }

    @Test(arguments: SidebarTextSize.allCases)
    func expandedBandRowsAreComfortableRows(text: SidebarTextSize) {
        let expanded = Self.tokens(.expanded, text)
        let comfortable = Self.tokens(.comfortable, text)
        #expect(expanded.band.rowHeight == comfortable.rowHeight)
        #expect(expanded.band.rowHeight > expanded.rowHeight)
    }

    @Test(arguments: SidebarTextSize.allCases)
    func expandedHoverCardIsComfortableCard(text: SidebarTextSize) {
        #expect(Self.tokens(.expanded, text).hoverCard == Self.tokens(.comfortable, text).hoverCard)
    }

    @Test(arguments: [SidebarDensity.compact, .comfortable], SidebarTextSize.allCases)
    func compactAndComfortableKeepTheirOwnBand(density: SidebarDensity, text: SidebarTextSize) {
        let tokens = Self.tokens(density, text)
        #expect(tokens.band == tokens)
    }

    @Test func expandedListRowsKeepTheAppRow() {
        #expect(Self.tokens(.expanded).rowHeight == 24)
        #expect(Self.tokens(.expanded).horizontalInset == 6)
    }
}
