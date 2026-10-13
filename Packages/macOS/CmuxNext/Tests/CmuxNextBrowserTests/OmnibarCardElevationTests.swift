import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// Coherence pass (Leo 10-13, cx-iif6y): the omnibar's suggestion card is a popup like every
/// other menu and popover, so it takes the one popup corner and shadow (`PopupStyle.standard`)
/// rather than a rounder card with a darker shadow of its own. Both halves of the card (the part
/// around the bar and the panel of rows below it) match, or the seam between them shows.
@MainActor
struct OmnibarCardElevationTests {
    private let style = PopupStyle.standard

    @Test func theSuggestionCardIsThePopupCornerAndShadow() throws {
        let panel = SuggestionCardView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let top = OmnibarCardTopView(frame: NSRect(x: 0, y: 0, width: 400, height: 34))
        let layers = [try #require(panel.card.layer), try #require(top.layer?.sublayers?.first)]
        for layer in layers {
            #expect(layer.cornerRadius == style.cornerRadius)
            #expect(abs(CGFloat(layer.shadowOpacity) - style.shadowAlpha) < 0.001)
            #expect(layer.shadowRadius == style.shadowBlur)
            #expect(layer.shadowOffset == CGSize(width: 0, height: -style.shadowOffset))
        }
    }
}
