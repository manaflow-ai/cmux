#if os(iOS)
import Testing
@testable import CmuxMobileWorkspaces

/// The row you come back to shows the selection fill and then clears it; no row stays drawn as
/// selected (Aziz, TestFlight, 2026-11-25: "Browser Dogfood" stayed filled after every pop).
@MainActor @Suite struct ReturnHighlightTests {
    @Test func pushThenPopFlashesTheRowThenClearsIt() {
        var highlight = ReturnHighlight()
        #expect(highlight.flashing == nil)
        highlight.opened("ws-browser-dogfood")
        // Pushed: nothing is drawn as selected under the workspace's page.
        #expect(highlight.flashing == nil)
        #expect(highlight.appeared() == "ws-browser-dogfood")
        #expect(highlight.flashing == "ws-browser-dogfood")
        highlight.ended()
        #expect(highlight.flashing == nil, "a row stayed selected after the pop")
    }

    @Test func aSecondAppearanceWithoutAPushFlashesNothing() {
        var highlight = ReturnHighlight()
        highlight.opened("a")
        _ = highlight.appeared()
        highlight.ended()
        // Another tab and back, a sheet, a relaunch's appearance: no push from the list.
        #expect(highlight.appeared() == nil)
        #expect(highlight.flashing == nil)
    }

    @Test func theLastPushIsTheOneThatFlashes() {
        var highlight = ReturnHighlight()
        highlight.opened("a")
        highlight.opened("b")
        #expect(highlight.appeared() == "b")
        highlight.ended()
        #expect(highlight.flashing == nil)
    }

    @Test func theLaunchRestoreFlashesOnceAndClears() {
        var highlight = ReturnHighlight()
        highlight.flash("ws-last")
        #expect(highlight.flashing == "ws-last")
        highlight.ended()
        #expect(highlight.flashing == nil)
    }
}
#endif
