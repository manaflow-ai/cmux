import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite
struct MobileCoreRPCIndependentEventTests {
    @Test
    func independentlyFramedEventsReachTheExistingListenerPipeline() async throws {
        let route = try irohRoute(hexBytePair: "ab")
        let source = IndependentEventSource()
        let runtime = TestMobileSyncRuntime(
            transportFactory: FixedTransportFactory(transport: NeverConnectedTransport()),
            independentEventByteStreamProvider: { request in
                #expect(request.route == route)
                return await source.makeStream()
            }
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: try ticket(route: route, deviceSuffix: "004")
        )
        let subscription = await client.subscribe(to: ["terminal.render_grid"])
        var events = subscription.makeAsyncIterator()

        #expect(await client.prepareIndependentServerEvents())

        let envelope = try JSONSerialization.data(withJSONObject: [
            "kind": "event",
            "topic": "terminal.render_grid",
            "payload": ["surface_id": "terminal-1"],
        ])
        let frame = try MobileSyncFrameCodec.encodeFrame(envelope)
        await source.yield(Data(frame.prefix(3)))
        await source.yield(Data(frame.dropFirst(3)))

        let event = await events.next()
        #expect(event?.topic == "terminal.render_grid")
        let payload = try #require(event?.payloadJSON)
        let object = try #require(
            JSONSerialization.jsonObject(with: payload) as? [String: String]
        )
        #expect(object["surface_id"] == "terminal-1")

        await client.disconnect()
    }

    @Test
    func independentStreamFailureDoesNotFinishControlEventListeners() async throws {
        let route = try irohRoute(hexBytePair: "cd")
        let source = IndependentEventSource()
        let runtime = TestMobileSyncRuntime(
            transportFactory: FixedTransportFactory(transport: NeverConnectedTransport()),
            independentEventByteStreamProvider: { _ in await source.makeStream() }
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: try ticket(route: route, deviceSuffix: "005")
        )
        _ = await client.subscribe(to: ["workspace.updated"])

        #expect(await client.prepareIndependentServerEvents())
        await source.finish(throwing: IndependentEventTestError.closed)

        for _ in 0 ..< 100 where await client.session.hasIndependentEventReaderForTesting {
            await Task.yield()
        }
        #expect(!(await client.session.hasIndependentEventReaderForTesting))
        #expect(await client.session.eventListenerCountForTesting == 1)

        await client.disconnect()
    }

    private func irohRoute(hexBytePair: String) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(
                    endpointID: String(repeating: hexBytePair, count: 32)
                ),
                pathHints: []
            )
        )
    }

    private func ticket(
        route: CmxAttachRoute,
        deviceSuffix: String
    ) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "123e4567-e89b-42d3-a456-426614174\(deviceSuffix)",
            macDisplayName: "Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(60),
            authToken: nil
        )
    }
}

private enum IndependentEventTestError: Error {
    case closed
}

private actor IndependentEventSource {
    private var continuation: AsyncThrowingStream<Data, any Error>.Continuation?

    func makeStream() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            self.continuation = continuation
        }
    }

    func yield(_ data: Data) {
        continuation?.yield(data)
    }

    func finish(throwing error: any Error) {
        continuation?.finish(throwing: error)
        continuation = nil
    }
}

private actor NeverConnectedTransport: CmxByteTransport {
    func connect() async throws {}
    func receive() async throws -> Data? { nil }
    func send(_: Data) async throws {}
    func close() async {}
}
