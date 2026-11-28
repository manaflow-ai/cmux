import Testing
@testable import CmuxNextSettings

/// A hidden browser page is discarded (and so reloads when selected) only once cmux.json sets `browser.hibernation`
/// (Leo 2026-10-26: "why does cmux-next's browser keep refreshing and reloading?"). With no setting a hidden page only
/// freezes, so a reload on a plain tab switch comes from elsewhere (the hide dropping the page's frame, or a renderer
/// that exited), not from the default hibernation.
struct BrowserHibernationDefaultTests {
    @Test func theDefaultNeverDiscardsAHiddenPage() {
        #expect(!BrowserHibernationSetting.fallback.discardsAutomatically)
        #expect(BrowserHibernationSetting.fallback.freezeSeconds != nil)
    }
}
