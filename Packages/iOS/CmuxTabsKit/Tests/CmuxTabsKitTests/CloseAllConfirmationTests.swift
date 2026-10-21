@testable import CmuxTabsKit
import Testing

/// Close All Tabs asks first, as Safari does: one tap on the grid's More menu
/// closed every tab of a workspace with no way back (cnx-ios live recheck, 2026-10-20).
struct CloseAllConfirmationTests {
    @Test func namesHowManyTabsClose() {
        #expect(CloseAllConfirmation(ids: ["a", "b", "c", "d", "e"]).confirmTitle == "Close All 5 Tabs")
        #expect(CloseAllConfirmation(ids: ["a"]).confirmTitle == "Close 1 Tab")
        #expect(CloseAllConfirmation(ids: ["a", "b", "c", "d", "e"]).message == "This can’t be undone.")
    }

    /// The tabs asked about are the ones closed, even if the host lists another meanwhile.
    @Test func closesTheTabsItAskedAbout() {
        #expect(CloseAllConfirmation(ids: ["a", "b"]).ids == ["a", "b"])
    }
}
