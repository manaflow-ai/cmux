@testable import CmuxNextApp
import CmuxNextControl
import Testing

/// Which agent page operations create a Chromium tab's browser first. A tab
/// `cmux open` made in the background has no browser until a pane shows it;
/// an operation that runs page script without one failed with `js_error`
/// "closed". `cmux browser TAB wait` (an async page script) timed out for
/// 40 s and more on such a tab while `eval` on it worked.
@Suite struct BrowserPageLiveBrowserTests {
    @Test(arguments: [
        BrowserPageOperation.evaluate("1"),
        .evaluateAsync("return 1"),
        .screenshot(.viewport),
        .cookies(.list),
    ])
    func pageScriptsAndCapturesStartTheBrowser(_ operation: BrowserPageOperation) {
        #expect(AppBrowserPage.needsLiveBrowser(operation), "\(operation) runs on a page that has no browser yet")
    }

    @Test(arguments: [
        BrowserPageOperation.state,
        .navigate("https://example.com"),
        .back, .forward, .reload,
    ])
    func addressAndHistoryStepsDoNotStartTheBrowser(_ operation: BrowserPageOperation) {
        #expect(!AppBrowserPage.needsLiveBrowser(operation))
    }
}
