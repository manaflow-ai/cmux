import Foundation
import Testing
import WebKit
@testable import CmuxBrowser

@Suite("Chromium browser engine session")
@MainActor
struct ChromiumBrowserEngineSessionTests {
    @Test
    func createsIsolatedWorldWithUniversalAccess() {
        #expect(ChromiumBrowserEngineSession.isolatedWorldParameters(frameID: "main-frame") == [
            "frameId": .string("main-frame"),
            "worldName": .string("cmux.browser.automation"),
            "grantUniversalAccess": .bool(true),
        ])
    }

    @Test
    func boundsScreencastFrameCadence() {
        #expect(ChromiumBrowserEngineSession.screencastParameters(
            viewportWidth: 640,
            viewportHeight: 480
        ) == [
            "format": .string("jpeg"),
            "quality": .number(75),
            "maxWidth": .number(1_280),
            "maxHeight": .number(960),
            "everyNthFrame": .number(2),
        ])
    }

    @Test
    func startsAndStopsScreencastWithViewportVisibility() {
        #expect(ChromiumBrowserEngineSession.screencastMethod(
            isViewportVisible: false,
            isScreencastActive: false
        ) == nil)
        #expect(ChromiumBrowserEngineSession.screencastMethod(
            isViewportVisible: true,
            isScreencastActive: false
        ) == "Page.startScreencast")
        #expect(ChromiumBrowserEngineSession.screencastMethod(
            isViewportVisible: false,
            isScreencastActive: true
        ) == "Page.stopScreencast")
    }

    @Test
    func forwardsCompositionAndCommittedTextToCDPInputCommands() {
        let session = ChromiumBrowserEngineSession(
            viewportWebView: WKWebView(),
            application: nil,
            userDataDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        defer { session.close() }

        session.handleViewportMessage([
            "type": "composition",
            "text": "に",
            "selectionStart": 1,
            "selectionEnd": 1,
        ])
        session.handleViewportMessage([
            "type": "text",
            "text": "日本",
        ])

        #expect(session.viewportInputQueue.commands.map(\.method) == [
            "Input.imeSetComposition",
            "Input.insertText",
        ])
        #expect(session.viewportInputQueue.commands[0].parameters == [
            "text": .string("に"),
            "selectionStart": .number(1),
            "selectionEnd": .number(1),
        ])
        #expect(session.viewportInputQueue.commands[1].parameters == [
            "text": .string("日本"),
        ])
    }

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
