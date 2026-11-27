import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// Coherence pass (Leo 10-13, cx-iif6y): the omnibar's suggestion card is a popup like every
/// other menu and popover, so the part around the bar casts the one popup shadow rather than a
/// darker one of its own. (Its corners are the bar's own, so bar and card are one shape.) The panel of rows casts none:
/// it floats over the bar, so a shadow reaching up to the seam would darken the bar.
@MainActor
struct OmnibarCardElevationTests {
    private let style = PopupStyle.standard

    @Test func theSuggestionCardIsThePopupCornerAndShadow() throws {
        let panel = SuggestionCardView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        panel.cardFrame = NSRect(x: 6, y: 0, width: 388, height: 180)
        panel.layout()
        let rows = try #require(panel.card.layer)
        #expect(panel.card.shadow == nil && rows.shadowPath == nil, "the rows cast no shadow over the bar")

        let top = OmnibarCardTopView(frame: NSRect(x: 0, y: 0, width: 400, height: 34)).card
        #expect(abs(CGFloat(top.shadowOpacity) - style.elevation.alpha) < 0.001)
        #expect(top.shadowRadius == style.elevation.layerRadius)
        #expect(top.shadowOffset == style.elevation.layerOffset())
    }
}
