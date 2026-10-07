import CmuxNextBrowser
import CmuxNextControl
import Foundation
import Testing
@testable import CmuxNextApp

/// nxdog63: `cmux browser navigate chrome://extensions` answered "Invalid url".
/// The page that loads the URL decides: a Chromium page opens Chromium's own
/// pages (the omnibar's resolver), whatever engine the tab record names; a
/// WebKit page refuses them by name instead of calling them invalid. The
/// agent refusals (password manager, settings, extension pages) run after
/// this, unchanged (AgentURLRefusalTests).
@MainActor @Suite struct BrowserNavigateTargetTests {
    @Test func aChromiumPageOpensChromePagesEvenWhenTheRecordNamesNoEngine() throws {
        for engine in [nil, BrowserEngineTag.cef.rawValue] {
            let url = try AppBrowserPage.navigationTarget("chrome://extensions", tabEngine: engine, page: .cef).get()
            #expect(url.absoluteString == "chrome://extensions/")
        }
    }

    @Test func aWebKitPageRefusesChromePagesByName() {
        guard case .failure(let error) = AppBrowserPage.navigationTarget("chrome://extensions", tabEngine: nil, page: .webkit) else {
            Issue.record("a WebKit page accepted chrome://extensions")
            return
        }
        #expect(error.code == "wrong_engine")
        #expect(error.message.contains("Chromium"))
    }

    @Test func webAddressesResolveOnEitherEngine() throws {
        for page in BrowserEngineKind.allCases {
            let url = try AppBrowserPage.navigationTarget("example.com", tabEngine: nil, page: page).get()
            #expect(url.host() == "example.com")
        }
        guard case .failure(let error) = AppBrowserPage.navigationTarget("", tabEngine: nil, page: .cef) else {
            Issue.record("an empty address resolved")
            return
        }
        #expect(error.code == "invalid_params")
    }
}
