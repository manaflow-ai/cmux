import CMUXMobileCore
import Foundation
@testable import CmuxIrohTransport

actor TestIrohEndpoint: CmxIrohEndpoint {
    private let peerIdentity: CmxIrohPeerIdentity
    private let directAddresses: [String]
    private var pathHints: [CmxIrohPathHint]
    private let pathHintsAfterRelayReplacement: [CmxIrohPathHint]?
    private let healthStream: AsyncStream<CmxIrohEndpointHealthEvent>
    private let healthContinuation: AsyncStream<CmxIrohEndpointHealthEvent>.Continuation
    private var closeCallCount = 0
    private var relayUpdates: [[CmxIrohRelayConfiguration]] = []
    private var relayProfileUpdates: [CmxIrohEndpointRelayProfile] = []
    private var relayUpdateShouldFail = false
    private var healthy = true

    init(
        identity: CmxIrohPeerIdentity,
        directAddresses: [String] = [],
        pathHints: [CmxIrohPathHint] = [],
        pathHintsAfterRelayReplacement: [CmxIrohPathHint]? = nil
    ) {
        peerIdentity = identity
        self.directAddresses = directAddresses
        self.pathHints = pathHints
        self.pathHintsAfterRelayReplacement = pathHintsAfterRelayReplacement
        let health = AsyncStream<CmxIrohEndpointHealthEvent>.makeStream()
        healthStream = health.stream
        healthContinuation = health.continuation
    }

    func identity() -> CmxIrohPeerIdentity {
        peerIdentity
    }

    func address() -> CmxIrohEndpointAddress {
        CmxIrohEndpointAddress(identity: peerIdentity, pathHints: pathHints)
    }

    func localDirectAddresses() -> [String] { directAddresses }

    func connect(
        to _: CmxIrohEndpointAddress,
        alpn _: Data
    ) async throws -> any CmxIrohConnection {
        throw TestIrohTransportError.unsupported
    }

    func accept() async throws -> (any CmxIrohConnection)? {
        nil
    }

    func replaceRelays(_ relays: [CmxIrohRelayConfiguration]) throws {
        if relayUpdateShouldFail {
            throw TestIrohTransportError.relayUpdateFailed
        }
        relayUpdates.append(relays)
        if let pathHintsAfterRelayReplacement {
            pathHints = pathHintsAfterRelayReplacement
        }
    }

    func replaceRelayProfile(_ profile: CmxIrohEndpointRelayProfile) throws {
        if relayUpdateShouldFail {
            throw TestIrohTransportError.relayUpdateFailed
        }
        relayProfileUpdates.append(profile)
    }

    func healthEvents() -> AsyncStream<CmxIrohEndpointHealthEvent> {
        healthStream
    }

    func isHealthy() -> Bool {
        healthy
    }

    func close() {
        closeCallCount += 1
        healthContinuation.finish()
    }

    func emit(_ event: CmxIrohEndpointHealthEvent) {
        healthContinuation.yield(event)
    }

    func setHealthy(_ value: Bool) {
        healthy = value
    }

    func setRelayUpdateShouldFail(_ shouldFail: Bool) {
        relayUpdateShouldFail = shouldFail
    }

    func observedCloseCallCount() -> Int {
        closeCallCount
    }

    func observedRelayUpdates() -> [[CmxIrohRelayConfiguration]] {
        relayUpdates
    }

    func observedRelayProfileUpdates() -> [CmxIrohEndpointRelayProfile] {
        relayProfileUpdates
    }
}
