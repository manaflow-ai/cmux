import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// Coherence pass (Leo 10-13, cx-iif6y): the omnibar's suggestion card is a popup like every
/// other menu and popover, so it takes the one popup corner and shadow (`PopupStyle.standard`)
/// rather than a rounder card with a darker shadow of its own. Both halves of the card (the part
/// around the bar and the panel of rows below it) match, or the seam between them shows. The
/// panel's card is a layer-backed view, whose shadow AppKit draws from the view's `shadow`; the
/// part around the bar is a plain layer that casts its own.
@MainActor
struct OmnibarCardElevationTests {
    private let style = PopupStyle.standard

    @Test func theSuggestionCardIsThePopupCornerAndShadow() throws {
        let panel = SuggestionCardView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let rows = try #require(panel.card.layer)
        #expect(rows.cornerRadius == style.cornerRadius)
        let shadow = try #require(panel.card.shadow, "the rows cast the popup shadow")
        #expect(shadow.shadowBlurRadius == style.shadowBlur)
        #expect(shadow.shadowOffset == NSSize(width: 0, height: -style.shadowOffset))
        #expect(abs((shadow.shadowColor?.alphaComponent ?? 0) - style.shadowAlpha) < 0.001)

        let top = OmnibarCardTopView(frame: NSRect(x: 0, y: 0, width: 400, height: 34)).card
        #expect(top.cornerRadius == style.cornerRadius)
        #expect(abs(CGFloat(top.shadowOpacity) - style.shadowAlpha) < 0.001)
        #expect(top.shadowRadius == style.shadowBlur)
        #expect(top.shadowOffset == CGSize(width: 0, height: -style.shadowOffset))
    }
}
