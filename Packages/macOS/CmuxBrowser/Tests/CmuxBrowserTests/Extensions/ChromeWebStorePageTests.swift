import Foundation
import Testing

@testable import CmuxBrowser

@Suite struct ChromeWebStorePageTests {
    @Test func recognizesStorePagesOverHTTPSOnly() throws {
        #expect(ChromeWebStorePage.isStorePage(try #require(URL(string: "https://chromewebstore.google.com/detail/x/bcjindcccaagfpapjjmafapmmgkkhgoa"))))
        #expect(ChromeWebStorePage.isStorePage(try #require(URL(string: "https://chrome.google.com/webstore/detail/bcjindcccaagfpapjjmafapmmgkkhgoa"))))
        #expect(!ChromeWebStorePage.isStorePage(try #require(URL(string: "http://chromewebstore.google.com/detail/x/bcjindcccaagfpapjjmafapmmgkkhgoa"))))
        #expect(!ChromeWebStorePage.isStorePage(try #require(URL(string: "https://chromewebstore.google.com.evil.test/detail/x/bcjindcccaagfpapjjmafapmmgkkhgoa"))))
        #expect(!ChromeWebStorePage.isStorePage(try #require(URL(string: "https://chrome.google.com/search?q=bcjindcccaagfpapjjmafapmmgkkhgoa"))))
    }

    /// The installed id comes from the detail path segment only, so a query
    /// string or fragment cannot substitute a different extension.
    @Test func readsExtensionIDFromDetailPathOnly() throws {
        let detail = try #require(URL(string: "https://chromewebstore.google.com/detail/json-formatter/bcjindcccaagfpapjjmafapmmgkkhgoa?ref=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
        #expect(ChromeWebStorePage.extensionID(onStorePage: detail) == "bcjindcccaagfpapjjmafapmmgkkhgoa")
        let queryOnly = try #require(URL(string: "https://chromewebstore.google.com/category/extensions?id=bcjindcccaagfpapjjmafapmmgkkhgoa"))
        #expect(ChromeWebStorePage.extensionID(onStorePage: queryOnly) == nil)
        let offStore = try #require(URL(string: "https://example.com/detail/bcjindcccaagfpapjjmafapmmgkkhgoa"))
        #expect(ChromeWebStorePage.extensionID(onStorePage: offStore) == nil)
    }

    @Test func userScriptEmbedsLabelsAsJSON() {
        let script = ChromeWebStorePage.userScriptSource(
            labels: .init(add: "Add \"to\" cmux", adding: "Adding…", added: "Added")
        )
        #expect(script.contains(#""add":"Add \"to\" cmux""#))
        #expect(script.contains(ChromeWebStorePage.messageHandlerName))
    }

    @Test func stateScriptSerializesInstallState() {
        let script = ChromeWebStorePage.stateUpdateScript(.init(installed: ["bcjindcccaagfpapjjmafapmmgkkhgoa"], busy: nil))
        #expect(script.contains(#""installed":["bcjindcccaagfpapjjmafapmmgkkhgoa"]"#))
    }
}
