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

    @Test("Paused document requests survive a burst beyond the normal event bound")
    func pausedRequestsAreNeverEvicted() async throws {
        let transport = PolicyCDPTransport()
        let connection = ChromiumCDPConnection(transport: transport)
        try await connection.connect()
        let events = await connection.events()
        let pausedCount = 520

        for index in 0..<pausedCount {
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

        let received = await withTaskGroup(of: [String]?.self) { group in
            group.addTask {
                var requestIDs: [String] = []
                var iterator = events.makeAsyncIterator()
                for _ in 0..<pausedCount {
                    guard let event = await iterator.next(),
                          event.method == "Fetch.requestPaused",
                          case .object(let params) = event.params,
                          let requestID = params["requestId"]?.stringValue else {
                        return nil
                    }
                    requestIDs.append(requestID)
                }
                return requestIDs
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }

        let requestIDs = try #require(received)
        #expect(requestIDs.count == pausedCount)
        #expect(requestIDs == (0..<pausedCount).map { "paused-\($0)" })
        await connection.shutdown()
    }
}
