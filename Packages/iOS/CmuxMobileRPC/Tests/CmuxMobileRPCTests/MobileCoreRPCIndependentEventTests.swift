import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite
struct MobileCoreRPCIndependentEventTests {
    @Test
    func retireReturnsPromptlyAndDisposesTransportAllocatedAfterRetirement() async throws {
        let route = try irohRoute(hexBytePair: "89")
        let transport = CloseTrackingNeverConnectedTransport()
        let factory = BlockingTransportFactory(transport: transport)
        let runtime = TestMobileSyncRuntime(transportFactory: factory)
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: try ticket(route: route, deviceSuffix: "001")
        )
        let request = try MobileCoreRPCClient.requestData(method: "mobile.host.status")
        let requestTask = Task { try? await client.sendRequest(request) }

        #expect(await pollUntil { factory.didEnter() })
        let retireCompleted = AsyncFlag()
        let retireTask = Task.detached {
            client.retire()
            await retireCompleted.set()
        }
        let retiredPromptly = await pollUntil { await retireCompleted.isSet() }
        factory.release()
        await retireTask.value
        _ = await requestTask.value

        #expect(retiredPromptly)
        #expect(await pollUntil { await transport.wasClosed() })
        await client.disconnect()
    }

    @Test
    func retireDisposesIndependentEventStreamCreatedAfterRetirement() async throws {
        let route = try irohRoute(hexBytePair: "90")
        let source = SuspendedIndependentEventSource()
        let runtime = TestMobileSyncRuntime(
            transportFactory: FixedTransportFactory(transport: NeverConnectedTransport()),
            independentEventByteStreamProvider: { _ in try await source.makeStream() }
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: try ticket(route: route, deviceSuffix: "002")
        )
        let preparation = Task { await client.prepareIndependentServerEvents() }
        await source.waitUntilRequested()

        client.retire()
        await source.resume()

        #expect(!(await preparation.value))
        #expect(await pollUntil { await source.wasTerminated() })
        await client.disconnect()
    }

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

    @Test
    func repeatedSubscriptionDoesNotReopenEndedIndependentEventLane() async throws {
        let route = try irohRoute(hexBytePair: "de")
        let source = OneShotIndependentEventSource()
        let transport = SubscribeRoundTripTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: FixedTransportFactory(transport: transport),
            independentEventByteStreamProvider: { _ in try await source.makeStream() }
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: try ticket(route: route, deviceSuffix: "006")
        )
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.events.subscribe",
            params: [
                "stream_id": "events",
                "topics": ["terminal.updated"],
            ]
        )

        _ = try await client.sendRequest(request)
        await source.finishFirstStream()
        #expect(await pollUntil { await client.session.independentEventReader == nil })

        do {
            let responseData = try await client.sendRequest(
                request,
                timeoutNanoseconds: 500_000_000
            )
            let response = try MobileEventSubscribeResponse.decode(responseData)
            #expect(response.eventTransport == "control_v1")
        } catch {
            Issue.record("A repeated subscription must retain budget for the control RPC: \(error)")
        }

        #expect(await source.observedRequestCount() == 1)
        #expect(
            await transport.recordedEventTransports()
                == ["iroh_server_events_v1", nil]
        )
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

private func pollUntil(
    attempts: Int = 1_000,
    condition: () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}

private final class BlockingTransportFactory: CmxByteTransportFactory, @unchecked Sendable {
    private let transport: any CmxByteTransport
    private let lock = NSLock()
    private let releaseGate = DispatchSemaphore(value: 0)
    private var entered = false

    init(transport: any CmxByteTransport) {
        self.transport = transport
    }

    func makeTransport(for _: CmxAttachRoute) throws -> any CmxByteTransport {
        lock.withLock { entered = true }
        releaseGate.wait()
        return transport
    }

    func didEnter() -> Bool { lock.withLock { entered } }
    func release() { releaseGate.signal() }
}

private actor SuspendedIndependentEventSource {
    private var requested = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var released = false
    private var terminated = false

    func makeStream() async throws -> CmxIndependentEventByteStream {
        requested = true
        let waiters = requestWaiters
        requestWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { await self?.recordTermination() }
            }
        }
    }

    func waitUntilRequested() async {
        guard !requested else { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func resume() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func wasTerminated() -> Bool { terminated }

    private func recordTermination() { terminated = true }
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

private actor OneShotIndependentEventSource {
    private let first = IndependentEventSource()
    private var requestCount = 0

    func makeStream() async throws -> CmxIndependentEventByteStream {
        requestCount += 1
        if requestCount == 1 {
            return await first.makeStream()
        }
        try await Task.sleep(nanoseconds: 60_000_000_000)
        throw IndependentEventTestError.closed
    }

    func finishFirstStream() async {
        await first.finish(throwing: IndependentEventTestError.closed)
    }

    func observedRequestCount() -> Int { requestCount }
}

private actor NeverConnectedTransport: CmxByteTransport {
    func connect() async throws {}
    func receive() async throws -> Data? { nil }
    func send(_: Data) async throws {}
    func close() async {}
}

private actor CloseTrackingNeverConnectedTransport: CmxByteTransport {
    private var closed = false

    func connect() async throws {}
    func receive() async throws -> Data? { nil }
    func send(_: Data) async throws {}
    func close() async { closed = true }

    func wasClosed() -> Bool { closed }
}

private actor SubscribeRoundTripTransport: CmxByteTransport {
    private var replies: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var eventTransports: [String?] = []
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
        let eventTransport = params?["event_transport"] as? String
        eventTransports.append(eventTransport)
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
        eventTransports.last ?? nil
    }

    func recordedEventTransports() -> [String?] { eventTransports }
}
