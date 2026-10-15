import CmuxBrowser
import CmuxCEF
import Foundation
import Testing
@testable import CmuxCEFBrowser

@MainActor
@Suite
struct CEFBrowserPageUserScriptTests {
    private func makePage() -> CEFBrowserPage {
        let browser = CEFBrowser(configuration: CEFBrowserConfiguration(profile: UUID()))
        return CEFBrowserPage(
            browser: browser,
            shim: { nil },
            devToolsLayoutStore: BrowserDevToolsLayoutStore(
                defaults: UserDefaults(suiteName: "CEFBrowserPageUserScriptTests.\(UUID().uuidString)")!
            )
        )
    }

    @Test func scriptsAddedBeforeTheBrowserExistsAreQueued() {
        let page = makePage()
        defer { page.close() }
        page.addUserScript(BrowserPageUserScript(source: "window.a = 1", injectionTime: .documentStart))
        page.addUserScript(BrowserPageUserScript(source: "window.b = 2", injectionTime: .documentEnd, isMainFrameOnly: false))
        #expect(page.pendingUserScriptSources.count == 2)
        #expect(page.pendingUserScriptSources[0].contains("window.a = 1"))
        #expect(page.pendingUserScriptSources[1].contains("DOMContentLoaded"))
        page.removeAllUserScripts()
        #expect(page.pendingUserScriptSources.isEmpty)
    }

    @Test func userScriptSourceWrapsByInjectionTimeAndFrame() {
        let start = CEFBrowserPage.userScriptSource(BrowserPageUserScript(source: "x()", injectionTime: .documentStart))
        #expect(start.hasPrefix("if (window === window.top)"))
        #expect(!start.contains("DOMContentLoaded"))
        let end = CEFBrowserPage.userScriptSource(
            BrowserPageUserScript(source: "y()", injectionTime: .documentEnd, isMainFrameOnly: false)
        )
        #expect(end.contains("DOMContentLoaded"))
        #expect(!end.contains("window.top"))
    }

    @Test func registeringWithoutAShimDropsTheQueueSafely() {
        let page = makePage()
        defer { page.close() }
        page.addUserScript(BrowserPageUserScript(source: "z()", injectionTime: .documentStart))
        page.registerPendingUserScripts(browserID: 7)
        #expect(page.pendingUserScriptSources.isEmpty)
    }
}
