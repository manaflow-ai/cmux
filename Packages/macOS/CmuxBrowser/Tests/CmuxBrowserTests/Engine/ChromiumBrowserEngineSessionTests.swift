import Foundation
import Testing
import WebKit
@testable import CmuxBrowser

@Suite("Chromium browser engine session")
@MainActor
struct ChromiumBrowserEngineSessionTests {
    @Test
    func createsIsolatedWorldWithUniversalAccess() {
        #expect(ChromiumIsolatedWorldConfiguration(frameID: "main-frame").parameters == [
            "frameId": .string("main-frame"),
            "worldName": .string("cmux.browser.automation"),
            "grantUniversalAccess": .bool(true),
        ])
    }

    @Test
    func boundsScreencastFrameCadence() {
        #expect(ChromiumScreencastConfiguration(
            viewportWidth: 640,
            viewportHeight: 480
        ).parameters == [
            "format": .string("jpeg"),
            "quality": .number(75),
            "maxWidth": .number(1_280),
            "maxHeight": .number(960),
            "everyNthFrame": .number(2),
        ])
    }

    @Test
    func startsAndStopsScreencastWithViewportVisibility() {
        #expect(ChromiumScreencastTransition(
            isViewportVisible: false,
            isScreencastActive: false
        ).method == nil)
        #expect(ChromiumScreencastTransition(
            isViewportVisible: true,
            isScreencastActive: false
        ).method == "Page.startScreencast")
        #expect(ChromiumScreencastTransition(
            isViewportVisible: false,
            isScreencastActive: true
        ).method == "Page.stopScreencast")
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
    func localInputBackpressureDoesNotEndTheSession() {
        let session = ChromiumBrowserEngineSession(
            viewportWebView: WKWebView(),
            application: nil,
            userDataDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        defer { session.close() }

        for index in 0..<ChromiumViewportInputQueue.maximumPendingCommands {
            session.handleViewportMessage([
                "type": "key",
                "event": "keyDown",
                "key": String(index),
                "code": "Key\(index)",
            ])
        }
        session.handleViewportMessage([
            "type": "key",
            "event": "keyUp",
            "key": "0",
            "code": "Key0",
        ])

        #expect(session.viewportInputQueue.count == ChromiumViewportInputQueue.maximumPendingCommands)
        #expect(session.viewportInputFailed == false)
    }

    @Test
    func runtimeTitleBindingUpdatesTheLiveEngineTitle() async {
        let session = ChromiumBrowserEngineSession(
            viewportWebView: WKWebView(),
            application: nil,
            userDataDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let connection = CDPConnection(url: URL(string: "ws://localhost.invalid")!)
        defer { session.close() }

        await session.handle(
            CDPEvent(
                method: "Runtime.bindingCalled",
                parameters: [
                    "name": .string("__cmuxChromiumTitleChanged"),
                    "payload": .string("Updated by the SPA"),
                ],
                sessionID: "test-session"
            ),
            connection: connection,
            sessionID: "test-session"
        )

        #expect(session.state.title == "Updated by the SPA")
        await connection.close()
    }

    @Test
    func navigationCompletionRevisionAdvancesOnlyForCompletedLoads() async {
        let session = ChromiumBrowserEngineSession(
            viewportWebView: WKWebView(),
            application: nil,
            userDataDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let transport = NavigationTestCDPTransport()
        let connection = CDPConnection(transport: transport)
        let sessionID = "test-session"
        await connection.connect()
        session.connection = connection
        session.cdpSessionID = sessionID
        defer { session.close() }

        let initialRevision = session.state.navigationCompletionRevision
        await session.handle(
            CDPEvent(
                method: "Page.loadEventFired",
                parameters: [:],
                sessionID: sessionID
            ),
            connection: connection,
            sessionID: sessionID
        )
        let completedRevision = session.state.navigationCompletionRevision

        await session.handle(
            CDPEvent(
                method: "Runtime.bindingCalled",
                parameters: [
                    "name": .string("__cmuxChromiumTitleChanged"),
                    "payload": .string("Updated after load"),
                ],
                sessionID: sessionID
            ),
            connection: connection,
            sessionID: sessionID
        )

        #expect(completedRevision == initialRevision + 1)
        #expect(session.state.navigationCompletionRevision == completedRevision)
        await connection.close()
    }

    @Test
    func subframeLifecycleDoesNotChangeTopLevelLoadingState() async {
        let session = ChromiumBrowserEngineSession(
            viewportWebView: WKWebView(),
            application: nil,
            userDataDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let connection = CDPConnection(url: URL(string: "ws://localhost.invalid")!)
        let sessionID = "test-session"
        defer { session.close() }

        await session.handle(
            CDPEvent(
                method: "Page.frameNavigated",
                parameters: [
                    "frame": .object([
                        "id": .string("main-frame"),
                        "url": .string("https://example.com"),
                    ]),
                ],
                sessionID: sessionID
            ),
            connection: connection,
            sessionID: sessionID
        )
        await session.handle(
            loadingEvent(method: "Page.frameStartedLoading", frameID: "child-frame", sessionID: sessionID),
            connection: connection,
            sessionID: sessionID
        )
        #expect(session.state.isLoading == false)

        await session.handle(
            loadingEvent(method: "Page.frameStartedLoading", frameID: "main-frame", sessionID: sessionID),
            connection: connection,
            sessionID: sessionID
        )
        await session.handle(
            loadingEvent(method: "Page.frameStoppedLoading", frameID: "child-frame", sessionID: sessionID),
            connection: connection,
            sessionID: sessionID
        )
        #expect(session.state.isLoading)

        await session.handle(
            loadingEvent(method: "Page.frameStoppedLoading", frameID: "main-frame", sessionID: sessionID),
            connection: connection,
            sessionID: sessionID
        )
        await session.handle(
            loadingEvent(method: "Page.frameStartedLoading", frameID: "child-frame", sessionID: sessionID),
            connection: connection,
            sessionID: sessionID
        )
        #expect(session.state.isLoading == false)
        await connection.close()
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

    @Test
    func preservesJavaScriptExceptionTextWithoutExposingProtocolErrors() {
        let exceptionText = "ReferenceError: missingValue is not defined"

        #expect(
            BrowserEngineSessionError.chromiumJavaScriptEvaluation(exceptionText)
                .localizedDescription == exceptionText
        )
        #expect(
            BrowserEngineSessionError.chromiumProtocol("secret protocol detail")
                .localizedDescription != "secret protocol detail"
        )
    }

    private func loadingEvent(method: String, frameID: String, sessionID: String) -> CDPEvent {
        CDPEvent(
            method: method,
            parameters: ["frameId": .string(frameID)],
            sessionID: sessionID
        )
    }
}
