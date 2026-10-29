@testable import CmuxNextBrowser
import CmuxNextTrace
import CmuxNextWakeups
import Testing

/// The app's open browser pages in the crash-key page: live WebKit pages and live Chromium
/// tabs are counted apart, as power-of-two buckets.
@MainActor @Suite(.serialized) struct CrashKeyBrowserCountTests {
    @Test func browserPagesAreCountedByEngine() {
        let keys = CrashKeySlots(), page = CrashKeyPage(identity: .init(role: .app))
        keys.page.attach(page)
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory())
        let tabs: [any BrowserTab] = (0 ..< 3).map { _ in engine.makeWebKitTab() }
        keys.noteBrowsers(in: tabs)
        #expect(page.value(.webKitViewCount) == 2, "3 WebKit pages are the 2 bucket")
        #expect(page.value(.chromiumBrowserCount) == 0)
        keys.noteBrowsers(in: [any BrowserTab]())
        #expect(page.value(.webKitViewCount) == 0)
    }
}
