import AppKit
import Testing
@testable import CmuxNextBrowser

/// The omnibar's profile badge draws a profile icon that is an SF Symbol
/// name ("globe") as the symbol, never as the text "globe"; an emoji or a
/// letter stays text (GPUI report, R88 follow-up).
@MainActor
struct ProfileBadgeViewTests {
    @Test func aSymbolNameDrawsTheSymbol() {
        let view = ProfileBadgeView()
        view.show(BrowserProfileBadge(monogram: "globe", color: nil, name: "Work"))
        #expect(view.shownSymbol == "globe")
        #expect(view.shownText.isEmpty, "the symbol name is never shown as text")
    }

    @Test func emojiAndLettersStayText() {
        let view = ProfileBadgeView()
        view.show(BrowserProfileBadge(monogram: "💼", color: nil, name: "Work"))
        #expect(view.shownSymbol == nil)
        #expect(view.shownText == "💼")
        view.show(BrowserProfileBadge(monogram: "W", color: nil, name: "Work"))
        #expect(view.shownSymbol == nil)
        #expect(view.shownText == "W")
    }
}
