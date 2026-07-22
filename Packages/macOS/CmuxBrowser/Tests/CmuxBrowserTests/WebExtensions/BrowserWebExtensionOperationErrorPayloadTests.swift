import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Browser WebExtension operation error payload")
struct BrowserWebExtensionOperationErrorPayloadTests {
    @Test func releasePayloadExcludesLocalizedDescriptionAndPath() throws {
        let sentinel = "secret extension failure at /Users/alice/private/manifest.json"
        let error = NSError(
            domain: "cmux.tests.web-extension",
            code: 73,
            userInfo: [NSLocalizedDescriptionKey: sentinel]
        )

        let payload = BrowserWebExtensionOperationErrorPayload(
            method: "browser.extensions.add",
            error: error,
            includeDebugDescription: false
        )
        let errorData = try #require(payload.foundationData["error"] as? [String: Any])
        let wireDescription = String(describing: payload.foundationData)

        #expect(payload.message == "Extension operation failed")
        #expect(payload.method == "browser.extensions.add")
        #expect(errorData["domain"] as? String == error.domain)
        #expect(errorData["code"] as? Int == error.code)
        #expect(Set(payload.foundationData.keys) == ["method", "error"])
        #expect(Set(errorData.keys) == ["domain", "code"])
        #expect(payload.debugDescription == nil)
        #expect(!payload.message.contains(sentinel))
        #expect(!wireDescription.contains(sentinel))
        #expect(!wireDescription.contains("/Users/alice"))
    }
}
