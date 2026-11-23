@testable import CmuxNextBrowser
import Foundation
import Testing

/// The tab of an extension's popup window (`chrome.windows.create`, adopted by `adoptPopupWindow`) is an
/// extension window (``BrowserTab/isExtensionWindow``); the pane tab cmux names its opener is not. The app
/// keeps the agent mark off extension windows (ExtensionWindowAgentMarkAppTests).
extension CEFSparePageSuites {
    @MainActor @Suite struct CEFExtensionWindowTests {
        typealias Fixture = CEFSparePageSuites.CEFSparePageTests

        @Test func anAdoptedPopupWindowIsAnExtensionWindowAndItsOpenerIsNot() throws {
            let (runtime, root) = try Fixture.runtime()
            defer { Fixture.tearDown(runtime, root) }
            let (host, opener, _) = try Fixture.liveHost(runtime)

            host.adoptPopupWindow(window: 7, browser: 40, bounds: nil, opener: opener)
            let popout = try #require(runtime.tabsByBrowser[40])
            #expect(popout.isExtensionWindow)
            #expect(!opener.isExtensionWindow)
        }
    }
}
