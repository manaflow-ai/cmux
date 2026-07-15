import Foundation
import Testing
@testable import CmuxBrowser

@Suite struct CDPConnectionTests {
    @Test func requestFailsAtItsDeadlineWhenChromiumNeverReplies() async {
        let connection = CDPConnection(
            transport: NoResponseCDPWebSocketTransport(),
            requestTimeout: .milliseconds(20)
        )

        await #expect(throws: BrowserEngineSessionError.self) {
            _ = try await connection.send(method: "Runtime.evaluate")
        }
        await connection.close()
    }

    @Test func cancellingCallerCancelsItsPendingRequest() async {
        let connection = CDPConnection(
            transport: NoResponseCDPWebSocketTransport(),
            requestTimeout: .seconds(5)
        )
        let request = Task {
            try await connection.send(method: "Page.captureScreenshot")
        }
        await Task.yield()

        request.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await request.value
        }
        await connection.close()
    }

    @Test func broadcastsBrowserEventsToEveryTargetSubscriber() async throws {
        let transport = BufferedCDPWebSocketTransport()
        let connection = CDPConnection(transport: transport)
        await connection.connect()
        let firstEvents = await connection.events(sessionID: "first-target")
        let secondEvents = await connection.events(sessionID: "second-target")
        let firstEvent = Task<CDPEvent?, Never> {
            for await event in firstEvents { return event }
            return nil
        }
        let secondEvent = Task<CDPEvent?, Never> {
            for await event in secondEvents { return event }
            return nil
        }
        let eventData = try JSONSerialization.data(withJSONObject: [
            "method": "Target.targetInfoChanged",
            "params": ["targetInfo": ["targetId": "browser"]],
        ])

        await transport.deliverAndWaitUntilConsumed(eventData)
        await connection.close()

        #expect(await firstEvent.value?.method == "Target.targetInfoChanged")
        #expect(await secondEvent.value?.method == "Target.targetInfoChanged")
    }
}
