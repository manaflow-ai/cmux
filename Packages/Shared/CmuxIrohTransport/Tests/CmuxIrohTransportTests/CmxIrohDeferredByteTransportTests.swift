import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohDeferredByteTransportTests {
    @Test
    func forwardsConnectedTransportContinuityAndClosureObservation() async throws {
        let underlying = ContinuityTransport(continuityID: 47)
        let transport = CmxIrohDeferredByteTransport(
            request: try request(),
            provider: DeferredProvider(transport: underlying)
        )

        try await transport.connect()

        let erased: any CmxByteTransport = transport
        let continuity = erased as? any CmxByteTransportContinuityIdentifying
        #expect(await continuity?.transportContinuityID() == 47)
        let closureObserver = erased as? any CmxByteTransportClosureObserving
        let observation = await closureObserver?.transportClosureObservation()
        #expect(observation != nil)

        await underlying.close()
        await observation?.waitUntilClosed()
        #expect(await underlying.didClose())
        #expect(await continuity?.transportContinuityID() == nil)
        await transport.close()
    }

    private func request() throws -> CmxByteTransportRequest {
        let peer = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "ab", count: 32)
        )
        return CmxByteTransportRequest(
            route: try CmxAttachRoute(
                id: "iroh",
                kind: .iroh,
                endpoint: .peer(identity: peer, pathHints: []),
                priority: 0
            ),
            expectedPeerDeviceID: "123e4567-e89b-42d3-a456-426614174004",
            authorizationMode: .transportAdmission
        )
    }
}

private struct DeferredProvider: CmxIrohDeferredTransportProviding {
    let transport: any CmxByteTransport

    func transport(
        for _: CmxByteTransportRequest
    ) async throws -> any CmxByteTransport {
        transport
    }
}

private actor ContinuityTransport:
    CmxByteTransport,
    CmxByteTransportClosureObserving,
    CmxByteTransportContinuityIdentifying
{
    private let continuityID: UInt64
    private var connected = false
    private var closed = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    init(continuityID: UInt64) {
        self.continuityID = continuityID
    }

    func connect() {
        connected = true
    }

    func receive() throws -> Data? {
        guard connected, !closed else {
            throw CmxIrohByteTransportError.notConnected
        }
        return nil
    }

    func send(_: Data) throws {
        guard connected, !closed else {
            throw CmxIrohByteTransportError.notConnected
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func transportContinuityID() -> UInt64? {
        guard connected, !closed else { return nil }
        return continuityID
    }

    func transportClosureObservation() -> CmxTransportClosureObservation? {
        guard connected, !closed else { return nil }
        return CmxTransportClosureObservation {
            await self.waitUntilClosed()
        }
    }

    func didClose() -> Bool {
        closed
    }

    private func waitUntilClosed() async {
        if closed { return }
        await withCheckedContinuation { continuation in
            closeWaiters.append(continuation)
        }
    }
}
