@testable import CmuxNextBrowser
@testable import CmuxNextDesign
import Testing

/// Lucas 2026-11-16: "concentric corners on the search across all densities". The suggestion card's highlighted row
/// keeps the card's corner less the room around it on every side it borders: the sides and, for the last row, the bottom.
@MainActor @Suite(.serialized) struct OmniboxCardConcentricTests {
    @Test(arguments: DensityPreset.allCases)
    func theLastRowIsConcentricWithTheCard(preset: DensityPreset) {
        DensityTokens.$scoped.withValue(preset.tokens) {
            let card = OmnibarStyle.cardCornerRadius, row = OmnibarStyle.rowCornerRadius
            #expect(OmnibarStyle.cardBottomPadding == OmnibarStyle.rowSideInset,
                    "\(preset): the last row sits \(OmnibarStyle.cardBottomPadding) over the card's bottom, \(OmnibarStyle.rowSideInset) in from its sides")
            #expect(abs(card - OmnibarStyle.rowSideInset - row) <= 0.5 || OmnibarStyle.rowSideInset == OmnibarStyle.edgeInset,
                    "\(preset): the card's corner \(card) less the inset \(OmnibarStyle.rowSideInset) is not the row's \(row)")
        }
    }
}
