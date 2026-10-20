@testable import CmuxTabsKit
import Testing

/// Close All Tabs asks first, as Safari does: one tap on the grid's More menu
/// closed every tab of a workspace with no way back (cnx-ios live recheck, 2026-10-20).
struct CloseAllConfirmationTests {
    @Test func namesHowManyTabsClose() {
        #expect(CloseAllConfirmation(count: 5).confirmTitle == "Close All 5 Tabs")
        #expect(CloseAllConfirmation(count: 1).confirmTitle == "Close 1 Tab")
        #expect(CloseAllConfirmation(count: 5).message == "This can’t be undone.")
    }
}
