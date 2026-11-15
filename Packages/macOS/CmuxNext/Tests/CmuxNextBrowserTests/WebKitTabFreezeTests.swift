@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Testing
import WebKit

/// A hidden WebKit page freezes like a Chromium one (`WebKitTab+Freeze`): the hibernation planner's
/// `freezer` finds a WebKit tab, and its freeze and thaw reach the page.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct WebKitTabFreezeTests {
    @Test func aWebKitTabFreezesAndThaws() async throws {
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory())
        let tab = engine.makeWebKitTab()
        defer { tab.close() }
        let freezing = try #require((tab as any BrowserTab) as? any BrowserFreezing)
        #expect(tab.webView.responds(to: WebKitTab.suspendSelector))
        #expect(freezing.setFrozen(true))
        #expect(freezing.setFrozen(false))
    }

    @Test func aClosedWebKitTabIgnoresAFreeze() {
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory())
        let tab = engine.makeWebKitTab()
        tab.close()
        #expect(!tab.setFrozen(true))
    }
}
