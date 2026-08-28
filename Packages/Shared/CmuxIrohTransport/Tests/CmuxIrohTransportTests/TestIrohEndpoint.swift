import CMUXMobileCore
import Foundation
@testable import CmuxIrohTransport

actor TestIrohEndpoint: CmxIrohEndpoint {
    private let peerIdentity: CmxIrohPeerIdentity
    private var directAddresses: [String]
    private var pathHints: [CmxIrohPathHint]
    private let pathHintsAfterRelayReplacement: [CmxIrohPathHint]?
    private let healthStream: AsyncStream<CmxIrohEndpointHealthEvent>
    private let healthContinuation: AsyncStream<CmxIrohEndpointHealthEvent>.Continuation
    private var closeCallCount = 0
    private var relayProfileUpdates: [CmxIrohEndpointRelayProfile] = []
    private var relayUpdateShouldFail = false
    private var healthy = true
    private var addressGateArmed = false
    private var blockedAddressArrivals = 0
    private var blockedAddressWaiters: [CheckedContinuation<Void, Never>] = []
    private var addressArrivalWaiters: [CheckedContinuation<Void, Never>] = []

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

    func address() async -> CmxIrohEndpointAddress {
        if addressGateArmed {
            blockedAddressArrivals += 1
            let arrivalWaiters = addressArrivalWaiters
            addressArrivalWaiters.removeAll()
            for waiter in arrivalWaiters { waiter.resume() }
            await withCheckedContinuation { blockedAddressWaiters.append($0) }
        }
        return CmxIrohEndpointAddress(identity: peerIdentity, pathHints: pathHints)
    }

    /// Blocks every subsequent `address()` read until released or disarmed,
    /// so tests can hold a registration refresh in flight at its payload read.
    func armAddressGate() {
        addressGateArmed = true
    }

    func disarmAddressGate() {
        addressGateArmed = false
        let blocked = blockedAddressWaiters
        blockedAddressWaiters.removeAll()
        for waiter in blocked { waiter.resume() }
    }

    func releaseOneBlockedAddressCall() {
        guard !blockedAddressWaiters.isEmpty else { return }
        blockedAddressWaiters.removeFirst().resume()
    }

    func waitForBlockedAddressArrivals(_ minimum: Int) async {
        while blockedAddressArrivals < minimum {
            await withCheckedContinuation { addressArrivalWaiters.append($0) }
        }
    }

    func localDirectAddresses() -> [String] { directAddresses }

    func setPathHints(_ hints: [CmxIrohPathHint]) {
        pathHints = hints
    }

    func setDirectAddresses(_ addresses: [String]) {
        directAddresses = addresses
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

    func replaceRelayProfile(_ profile: CmxIrohEndpointRelayProfile) throws {
        if relayUpdateShouldFail {
            throw TestIrohTransportError.relayUpdateFailed
        }
        relayProfileUpdates.append(profile)
        if let pathHintsAfterRelayReplacement {
            pathHints = pathHintsAfterRelayReplacement
        }
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

    func observedRelayProfileUpdates() -> [CmxIrohEndpointRelayProfile] {
        relayProfileUpdates
    }
}
