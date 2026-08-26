import CMUXMobileCore
import Foundation
@testable import CmuxIrohTransport

actor TestDialingIrohEndpoint: CmxIrohEndpoint {
    private let localIdentity: CmxIrohPeerIdentity
    private var dialResults: [TestIrohDialResult]
    private var dialedAddresses: [CmxIrohEndpointAddress] = []
    private let healthStream: AsyncStream<CmxIrohEndpointHealthEvent>
    private let healthContinuation: AsyncStream<CmxIrohEndpointHealthEvent>.Continuation

    init(
        localIdentity: CmxIrohPeerIdentity,
        dialResults: [TestIrohDialResult]
    ) {
        self.localIdentity = localIdentity
        self.dialResults = dialResults
        let health = AsyncStream<CmxIrohEndpointHealthEvent>.makeStream()
        healthStream = health.stream
        healthContinuation = health.continuation
    }

    func identity() -> CmxIrohPeerIdentity {
        localIdentity
    }

    func address() -> CmxIrohEndpointAddress {
        CmxIrohEndpointAddress(identity: localIdentity, pathHints: [])
    }

    func connect(
        to address: CmxIrohEndpointAddress,
        alpn _: Data
    ) async throws -> any CmxIrohConnection {
        dialedAddresses.append(address)
        guard !dialResults.isEmpty else {
            throw TestIrohTransportError.unsupported
        }
        switch dialResults.removeFirst() {
        case let .connection(connection):
            return connection
        case let .failure(error):
            throw error
        case .hang:
            // The production endpoint cancels its native ConnectAttempt. A
            // long cancellable sleep models that contract without leaving a
            // continuation behind when the phase bound wins.
            try await Task.sleep(for: .seconds(3_600))
            throw TestIrohTransportError.unsupported
        }
    }

    func accept() async throws -> (any CmxIrohIncomingConnection)? {
        nil
    }


    func healthEvents() -> AsyncStream<CmxIrohEndpointHealthEvent> {
        healthStream
    }

    func isHealthy() -> Bool { true }

    func close() {
        healthContinuation.finish()
    }

    func observedDialedAddresses() -> [CmxIrohEndpointAddress] {
        dialedAddresses
    }
}
