import CMUXMobileCore
import Foundation
@testable import CmuxIrohTransport

actor TestBlockingRelayUpdateEndpoint: CmxIrohEndpoint {
    private let peerIdentity: CmxIrohPeerIdentity
    private let healthStream: AsyncStream<CmxIrohEndpointHealthEvent>
    private let healthContinuation: AsyncStream<CmxIrohEndpointHealthEvent>.Continuation
    private let updateStream: AsyncStream<Void>
    private let updateContinuation: AsyncStream<Void>.Continuation
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(identity: CmxIrohPeerIdentity) {
        peerIdentity = identity
        let health = AsyncStream<CmxIrohEndpointHealthEvent>.makeStream()
        healthStream = health.stream
        healthContinuation = health.continuation
        let updates = AsyncStream<Void>.makeStream()
        updateStream = updates.stream
        updateContinuation = updates.continuation
    }

    func identity() -> CmxIrohPeerIdentity {
        peerIdentity
    }

    func address() -> CmxIrohEndpointAddress {
        CmxIrohEndpointAddress(identity: peerIdentity, pathHints: [])
    }

    func connect(
        to _: CmxIrohEndpointAddress,
        alpn _: Data
    ) async throws -> any CmxIrohConnection {
        throw TestIrohTransportError.unsupported
    }

    func accept() async throws -> (any CmxIrohConnection)? {
        nil
    }

    func replaceRelays(_: [CmxIrohRelayConfiguration]) async {
        updateContinuation.yield(())
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func healthEvents() -> AsyncStream<CmxIrohEndpointHealthEvent> {
        healthStream
    }

    func isHealthy() -> Bool { true }

    func close() {
        healthContinuation.finish()
    }

    func updateEvents() -> AsyncStream<Void> {
        updateStream
    }

    func releaseUpdate() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
