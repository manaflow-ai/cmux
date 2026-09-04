import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Chromium navigation interception")
@MainActor
struct ChromiumNavigationInterceptionTests {
    @Test("Blocked top-level document requests are failed before commit")
    func blockedTopLevelRequest() async throws {
        let transport = PolicyCDPTransport()
        let connection = ChromiumCDPConnection(transport: transport)
        try await connection.connect()
        let interceptor = ChromiumNavigationInterceptor(policyHandler: { request in
            #expect(request.request.url?.scheme == "http")
            return .cancel
        })
        try await interceptor.install(connection: connection)

        let handled = try await interceptor.handle(
            CDPEvent(
                method: "Fetch.requestPaused",
                params: .object([
                    "requestId": .string("request-1"),
                    "frameId": .string("main-frame"),
                    "resourceType": .string("Document"),
                    "request": .object([
                        "url": .string("http://insecure.example/"),
                        "method": .string("GET"),
                        "headers": .object([:]),
                    ]),
                ])
            ),
            connection: connection
        )

        #expect(handled)
        let commands = await transport.commands()
        #expect(commands.contains { command in
            command["method"] == .string("Fetch.failRequest") &&
                command["params"]?["requestId"] == .string("request-1")
        })
        await connection.shutdown()
    }

    @Test("Paused document requests stay lossless and fail explicitly at the bound")
    func pausedRequestsAreNeverEvicted() async throws {
        let transport = PolicyCDPTransport()
        let connection = ChromiumCDPConnection(transport: transport)
        try await connection.connect()
        let events = await connection.events()
        let pausedCount = 512
        let overflowCount = 8

        for index in 0..<(pausedCount + overflowCount) {
            let payload: [String: Any] = [
                "method": "Fetch.requestPaused",
                "params": [
                    "requestId": "paused-\(index)",
                    "resourceType": "Document",
                    "frameId": "frame-\(index)",
                ],
            ]
            await transport.emit(try JSONSerialization.data(withJSONObject: payload))
        }
        // Normal notifications are allowed to exercise the bounded queue;
        // they must not displace any of the paused flow-control events.
        for _ in 0..<pausedCount {
            await transport.emit(Data(#"{"method":"Page.lifecycleEvent","params":{}}"#.utf8))
        }

        var received: [String] = []
        var iterator = events.makeAsyncIterator()
        for _ in 0..<pausedCount {
            guard let event = await iterator.next(),
                  event.method == "Fetch.requestPaused",
                  case .object(let params) = event.params,
                  let requestID = params["requestId"]?.stringValue else {
                Issue.record("A queued paused request was not delivered")
                break
            }
            received.append(requestID)
        }

        let requestIDs = received
        #expect(requestIDs.count == pausedCount)
        #expect(requestIDs == (0..<pausedCount).map { "paused-\($0)" })
        await transport.waitForCommandCount(overflowCount)
        let overflowRequestIDs = await transport.commands().compactMap { value -> String? in
            guard case .object(let object) = value,
                  object["method"]?.stringValue == "Fetch.failRequest" else {
                return nil
            }
            return object["params"]?["requestId"]?.stringValue
        }
        #expect(overflowRequestIDs == (pausedCount..<(pausedCount + overflowCount)).map {
            "paused-\($0)"
        })
        await connection.shutdown()
    }
}
