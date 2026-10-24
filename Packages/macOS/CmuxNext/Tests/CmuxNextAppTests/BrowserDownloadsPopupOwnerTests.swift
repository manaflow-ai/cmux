@testable import CmuxNextApp
import Testing

/// The toolbar's Downloads popup is its download list's, not a process global: the app's one list
/// opens the same popup every time, and another list (another app, a test) has its own, closed one.
@MainActor @Suite struct BrowserDownloadsPopupOwnerTests {
    @Test func eachListHasItsOwnPopup() {
        let first = BrowserDownloadList(), second = BrowserDownloadList()
        #expect(first.popup === first.popup, "one popup per list")
        #expect(first.popup !== second.popup)
        #expect(!first.popup.isShown && !second.popup.isShown)
    }
}
