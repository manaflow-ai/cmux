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

    @Test func screencastPressureDoesNotEvictControlEvents() async throws {
        let transport = BufferedCDPWebSocketTransport()
        let connection = CDPConnection(transport: transport)
        await connection.connect()
        let events = await connection.events(sessionID: "target")
        let frames = await connection.screencastFrames(sessionID: "target")
        let controlEvent = try JSONSerialization.data(withJSONObject: [
            "method": "Fetch.requestPaused",
            "sessionId": "target",
            "params": ["requestId": "request-1"],
        ])
        await transport.deliverAndWaitUntilConsumed(controlEvent)

        for frameIndex in 0..<300 {
            let frame = try JSONSerialization.data(withJSONObject: [
                "method": "Page.screencastFrame",
                "sessionId": "target",
                "params": ["sessionId": frameIndex, "data": "frame"],
            ])
            await transport.deliverAndWaitUntilConsumed(frame)
        }

        var iterator = events.makeAsyncIterator()
        let retainedEvent = await iterator.next()
        let droppedFrameAcknowledgementCount = await transport.sentCommandCount(
            method: "Page.screencastFrameAck"
        )
        _ = frames
        await connection.close()

        #expect(retainedEvent?.method == "Fetch.requestPaused")
        #expect(droppedFrameAcknowledgementCount == 299)
    }

    @Test func controlEventPressureClosesConnectionInsteadOfGrowingWithoutBound() async throws {
        let transport = BufferedCDPWebSocketTransport()
        let connection = CDPConnection(transport: transport)
        await connection.connect()
        let events = await connection.events(sessionID: "target")
        let controlEvent = try JSONSerialization.data(withJSONObject: [
            "method": "Page.frameStartedLoading",
            "sessionId": "target",
            "params": ["frameId": "main"],
        ])

        for _ in 0..<300 {
            guard await connection.isOpen() else { break }
            await transport.deliverAndWaitUntilConsumed(controlEvent)
        }

        _ = events
        #expect(await connection.isOpen() == false)
        await connection.close()
    }
}
