import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite
struct MobileCoreRPCIndependentEventTests {
    @Test
    func subscribeAdvertisesIndependentDeliveryOnlyAfterReceiverPreparation() async throws {
        let route = try irohRoute(hexBytePair: "9a")
        let source = IndependentEventSource()
        let transport = SubscribeRoundTripTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: FixedTransportFactory(transport: transport),
            independentEventByteStreamProvider: { _ in await source.makeStream() }
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: try ticket(route: route, deviceSuffix: "003")
        )
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.events.subscribe",
            params: [
                "stream_id": "events",
                "topics": ["terminal.updated"],
            ]
        )

        _ = try await client.sendRequest(request)

        #expect(
            await transport.recordedEventTransport()
                == "iroh_server_events_v1"
        )
        await client.disconnect()
    }

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
        let listener = await client.subscribe(to: ["workspace.updated"])

        #expect(await client.prepareIndependentServerEvents())
        await source.finish(throwing: IndependentEventTestError.closed)

        for _ in 0 ..< 100 where await client.session.independentEventReader != nil {
            await Task.yield()
        }
        #expect(await client.session.independentEventReader == nil)
        #expect(await client.session.listeners.count == 1)
        _ = listener

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

private actor SubscribeRoundTripTransport: CmxByteTransport {
    private var replies: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var eventTransport: String?
    private var closed = false

    func connect() async throws {}

    func receive() async throws -> Data? {
        if !replies.isEmpty { return replies.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { waiter = $0 }
    }

    func send(_ data: Data) async throws {
        var buffer = data
        let payload = try #require(
            MobileSyncFrameCodec.decodeFrames(from: &buffer).first
        )
        let request = try #require(
            JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )
        let params = request["params"] as? [String: Any]
        eventTransport = params?["event_transport"] as? String
        let response = try JSONSerialization.data(withJSONObject: [
            "id": request["id"] ?? NSNull(),
            "ok": true,
            "result": [
                "stream_id": "events",
                "event_transport": eventTransport ?? "control_v1",
            ],
        ])
        let framed = try MobileSyncFrameCodec.encodeFrame(response)
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: framed)
        } else {
            replies.append(framed)
        }
    }

    func close() async {
        closed = true
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func recordedEventTransport() -> String? {
        eventTransport
    }
}
