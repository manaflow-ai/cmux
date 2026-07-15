import Foundation
import Testing
import WebKit
@testable import CmuxBrowser

@Suite("Chromium browser engine session")
@MainActor
struct ChromiumBrowserEngineSessionTests {
    @Test
    func rejectsNavigationRequestsWhoseSemanticsCannotBePreserved() {
        let url = URL(string: "https://example.com/submit")!

        var postRequest = URLRequest(url: url)
        postRequest.httpMethod = "POST"

        var headerRequest = URLRequest(url: url)
        headerRequest.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")

        var bodyRequest = URLRequest(url: url)
        bodyRequest.httpBody = Data("payload".utf8)

        let uncachedRequest = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData
        )

        for request in [postRequest, headerRequest, bodyRequest, uncachedRequest] {
            let session = ChromiumBrowserEngineSession(
                viewportWebView: WKWebView(),
                application: nil,
                userDataDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
            )
            let initialError = session.state.errorMessage
            session.load(request)

            #expect(session.state.url == nil)
            #expect(session.state.errorMessage != initialError)
            session.close()
        }
    }
}
