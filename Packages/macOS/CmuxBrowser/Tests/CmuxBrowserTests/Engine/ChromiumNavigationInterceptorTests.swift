import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Chromium navigation interception")
@MainActor
struct ChromiumNavigationInterceptorTests {
    @Test
    func cancelsRejectedTopLevelRequestBeforeCommit() async throws {
        let transport = NavigationTestCDPTransport()
        let connection = CDPConnection(transport: transport)
        await connection.connect()
        var observedRequest: BrowserEngineNavigationRequest?
        let interceptor = ChromiumNavigationInterceptor(
            targetID: "opener-target",
            policyHandler: { request in
                observedRequest = request
                return .cancel
            }
        )
        try await interceptor.install(connection: connection, sessionID: "opener-session")

        let handled = try await interceptor.handle(
            requestPausedEvent(url: "http://insecure.example/redirected"),
            connection: connection,
            sessionID: "opener-session"
        )

        #expect(handled)
        #expect(observedRequest?.request.url?.absoluteString == "http://insecure.example/redirected")
        #expect(observedRequest?.disposition == .currentTab)
        let commands = await transport.commands()
        #expect(commands.contains { command in
            command["method"] == .string("Fetch.failRequest") &&
                command["params"]?.objectValue?["requestId"] == .string("paused-request") &&
                command["params"]?.objectValue?["errorReason"] == .string("Aborted")
        })
        await connection.close()
    }

    @Test
    func continuesAllowedTopLevelRequest() async throws {
        let transport = NavigationTestCDPTransport()
        let connection = CDPConnection(transport: transport)
        await connection.connect()
        let interceptor = ChromiumNavigationInterceptor(
            targetID: "opener-target",
            policyHandler: { _ in .allow }
        )
        try await interceptor.install(connection: connection, sessionID: "opener-session")

        _ = try await interceptor.handle(
            requestPausedEvent(url: "https://example.com/allowed"),
            connection: connection,
            sessionID: "opener-session"
        )

        let commands = await transport.commands()
        #expect(commands.contains { command in
            command["method"] == .string("Fetch.continueRequest") &&
                command["params"]?.objectValue?["requestId"] == .string("paused-request")
        })
        await connection.close()
    }

    @Test
    func continuesSubframeDocumentWithoutApplyingTopLevelPolicy() async throws {
        let transport = NavigationTestCDPTransport()
        let connection = CDPConnection(transport: transport)
        await connection.connect()
        var policyInvocationCount = 0
        let interceptor = ChromiumNavigationInterceptor(
            targetID: "opener-target",
            policyHandler: { _ in
                policyInvocationCount += 1
                return .cancel
            }
        )
        try await interceptor.install(connection: connection, sessionID: "opener-session")

        _ = try await interceptor.handle(
            requestPausedEvent(
                url: "http://subframe.example/embedded",
                frameID: "child-frame"
            ),
            connection: connection,
            sessionID: "opener-session"
        )

        #expect(policyInvocationCount == 0)
        let commands = await transport.commands()
        #expect(commands.contains { command in
            command["method"] == .string("Fetch.continueRequest") &&
                command["params"]?.objectValue?["requestId"] == .string("paused-request")
        })
        await connection.close()
    }

    @Test
    func routesAndClosesNewWindowBeforeItCanResume() async throws {
        let transport = NavigationTestCDPTransport()
        let connection = CDPConnection(transport: transport)
        await connection.connect()
        var observedRequest: BrowserEngineNavigationRequest?
        let interceptor = ChromiumNavigationInterceptor(
            targetID: "opener-target",
            policyHandler: { request in
                observedRequest = request
                return .cancel
            }
        )
        try await interceptor.install(connection: connection, sessionID: "opener-session")

        let routed = try await interceptor.handle(
            CDPEvent(
                method: "Page.windowOpen",
                parameters: [
                    "url": .string("https://example.com/popup"),
                    "userGesture": .bool(true),
                    "windowFeatures": .array([]),
                ],
                sessionID: "opener-session"
            ),
            connection: connection,
            sessionID: "opener-session"
        )
        let closed = try await interceptor.handle(
            CDPEvent(
                method: "Target.attachedToTarget",
                parameters: [
                    "sessionId": .string("popup-session"),
                    "targetInfo": .object([
                        "targetId": .string("popup-target"),
                        "type": .string("page"),
                        "url": .string("https://example.com/popup"),
                        "openerId": .string("opener-target"),
                    ]),
                    "waitingForDebugger": .bool(true),
                ],
                sessionID: "opener-session"
            ),
            connection: connection,
            sessionID: "opener-session"
        )

        #expect(routed)
        #expect(closed)
        #expect(observedRequest?.request.url?.absoluteString == "https://example.com/popup")
        #expect(observedRequest?.disposition == .newTab)
        let commands = await transport.commands()
        #expect(commands.contains { command in
            command["method"] == .string("Target.closeTarget") &&
                command["params"]?.objectValue?["targetId"] == .string("popup-target")
        })
        #expect(!commands.contains { command in
            command["method"] == .string("Runtime.runIfWaitingForDebugger") &&
                command["sessionId"] == .string("popup-session")
        })
        await connection.close()
    }

    @Test
    func resumesNonPageTargetsPausedByAutoAttach() async throws {
        let transport = NavigationTestCDPTransport()
        let connection = CDPConnection(transport: transport)
        await connection.connect()
        let interceptor = ChromiumNavigationInterceptor(
            targetID: "opener-target",
            policyHandler: nil
        )
        try await interceptor.install(connection: connection, sessionID: "opener-session")

        let handled = try await interceptor.handle(
            CDPEvent(
                method: "Target.attachedToTarget",
                parameters: [
                    "sessionId": .string("worker-session"),
                    "targetInfo": .object([
                        "targetId": .string("worker-target"),
                        "type": .string("worker"),
                        "url": .string("https://example.com/worker.js"),
                    ]),
                    "waitingForDebugger": .bool(true),
                ],
                sessionID: "opener-session"
            ),
            connection: connection,
            sessionID: "opener-session"
        )

        #expect(handled)
        let commands = await transport.commands()
        #expect(commands.contains { command in
            command["method"] == .string("Runtime.runIfWaitingForDebugger") &&
                command["sessionId"] == .string("worker-session")
        })
        await connection.close()
    }

    private func requestPausedEvent(
        url: String,
        frameID: String = "main-frame"
    ) -> CDPEvent {
        CDPEvent(
            method: "Fetch.requestPaused",
            parameters: [
                "requestId": .string("paused-request"),
                "frameId": .string(frameID),
                "resourceType": .string("Document"),
                "request": .object([
                    "url": .string(url),
                    "method": .string("GET"),
                    "headers": .object([:]),
                ]),
            ],
            sessionID: "opener-session"
        )
    }
}
