import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

extension CmxIrohRelayCredentialCoordinatorTests {
    @Test
    func refreshFailureRetriesBeforeInstalledCredentialSafetyDeadline() async throws {
        let fixture = try RelayCoordinatorFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.identity)
        let supervisor = try await fixture.activeSupervisor(endpoint: endpoint)
        let broker = TestRelayTokenBroker(steps: [.failure])
        let clock = TestRelayClock(now: fixture.now)
        var clockEvents = clock.events().makeAsyncIterator()
        let expiresAt = fixture.now.addingTimeInterval(5 * 60)
        let refreshAfter = expiresAt.addingTimeInterval(-60)
        let coordinator = CmxIrohRelayCredentialCoordinator(
            supervisor: supervisor,
            broker: broker,
            managedRelayURLs: Set(fixture.relayURLs),
            clock: clock,
            jitter: { _, refreshAfter in refreshAfter },
            retryJitter: { 0 }
        )

        try await coordinator.activate(
            bindingID: fixture.bindingID,
            endpointIdentity: fixture.identity,
            bootstrap: try fixture.response(
                refreshAfter: refreshAfter,
                expiresAt: expiresAt
            )
        )
        #expect(await clockEvents.next() == .sleep(refreshAfter))

        clock.advance(to: refreshAfter)

        guard case let .sleep(retryDeadline) = await clockEvents.next() else {
            Issue.record("Expected a relay retry before credential expiry")
            return
        }
        #expect(retryDeadline == expiresAt.addingTimeInterval(-30))
        #expect(retryDeadline < expiresAt)
        #expect(await broker.observedEndpointIDs() == [fixture.identity])
        await coordinator.deactivate()
    }

    @Test
    func mismatchedBootstrapFleetNeverMutatesEndpoint() async throws {
        let fixture = try RelayCoordinatorFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.identity)
        let supervisor = try await fixture.activeSupervisor(endpoint: endpoint)
        let coordinator = CmxIrohRelayCredentialCoordinator(
            supervisor: supervisor,
            broker: TestRelayTokenBroker(steps: [.failure]),
            managedRelayURLs: Set(fixture.relayURLs),
            clock: TestRelayClock(now: fixture.now),
            jitter: { _, refreshAfter in refreshAfter },
            retryJitter: { 0 }
        )
        let incomplete = try fixture.response(relayURLs: [fixture.relayURLs[0]])

        await #expect(
            throws: CmxIrohRelayCredentialCoordinatorError.relayFleetMismatch
        ) {
            try await coordinator.activate(
                bindingID: fixture.bindingID,
                endpointIdentity: fixture.identity,
                bootstrap: incomplete
            )
        }
        await coordinator.deactivate()

        #expect(await endpoint.observedRelayUpdates().isEmpty)
        #expect(try await supervisor.activeEndpoint().identity() == fixture.identity)
    }
}
