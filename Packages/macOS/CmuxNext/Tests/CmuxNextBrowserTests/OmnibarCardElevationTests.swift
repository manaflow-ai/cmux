import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// Coherence pass (Leo 10-13, cx-iif6y): the omnibar's suggestion card is a popup like every
/// other menu and popover, so both halves of the card (the part around the bar and the panel of
/// rows below it) take the one popup corner (`PopupStyle.standard`), and the part around the bar
/// casts the one popup shadow rather than a darker one of its own. The panel of rows casts none:
/// it floats over the bar, so a shadow reaching up to the seam would darken the bar.
@MainActor
struct OmnibarCardElevationTests {
    private let style = PopupStyle.standard

    @Test func theSuggestionCardIsThePopupCornerAndShadow() throws {
        let panel = SuggestionCardView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        panel.cardFrame = NSRect(x: 6, y: 0, width: 388, height: 180)
        panel.layout()
        let rows = try #require(panel.card.layer)
        #expect(rows.cornerRadius == style.cornerRadius)
        #expect(panel.card.shadow == nil && rows.shadowPath == nil, "the rows cast no shadow over the bar")

        let top = OmnibarCardTopView(frame: NSRect(x: 0, y: 0, width: 400, height: 34)).card
        #expect(top.cornerRadius == style.cornerRadius)
        #expect(abs(CGFloat(top.shadowOpacity) - style.shadowAlpha) < 0.001)
        #expect(top.shadowRadius == style.shadowBlur / 2)
        #expect(top.shadowOffset == CGSize(width: 0, height: -style.shadowOffset))
    }
}
