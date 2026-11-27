import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

/// The gate audit of 2026-11-19 (item 5, PR B; Leo: "i wonder if there's more places we can
/// apply this principle"): the Mac fetched the broker again before admitting a phone whose signed
/// grant it had just verified, once its snapshot was 30 s old. A pair the Mac saw active in a
/// recent snapshot is now admitted on its signed grant at once; the broker is read behind it and
/// the lease monitor revalidates at once, cutting the session on disagreement.
@Suite
struct CmxIrohOnlineAdmissionRegistryCachedPairTests {
    @Test
    func aPairSeenActiveRecentlyIsAdmittedWithoutWaitingOnTheBroker() async throws {
        let fixture = try OnlineAdmissionFixture(grantLifetime: 3_600)
        let clock = OnlineAdmissionManualClock(now: fixture.now)
        let broker = OnlineAdmissionBroker(responses: [
            .success(try fixture.discovery()),
            .success(try fixture.discovery()),
        ])
        let registry = fixture.registry(broker: broker, clock: clock)
        #expect(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ).isAccepted
        )
        clock.advance(by: 45)
        await broker.suspend()

        let done = AdmissionDoneFlag()
        let admission = Task {
            let result = await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            )
            await done.set()
            return result
        }
        await broker.waitForCallCount(2)
        for _ in 0 ..< 1_024 {
            if await done.isSet() { break }
            await Task.yield()
        }

        // Admitted while the broker read is still held: nothing waited on it.
        #expect(await done.isSet())
        await broker.resume()
        #expect(await admission.value.isAccepted)
        #expect(await broker.callCount() == 2)
    }

    @Test
    func aPhoneRevokedSinceTheSnapshotIsCutByTheImmediateRevalidation() async throws {
        let fixture = try OnlineAdmissionFixture(grantLifetime: 3_600)
        let clock = OnlineAdmissionManualClock(now: fixture.now)
        let broker = OnlineAdmissionBroker(responses: [
            .success(try fixture.discovery()),
            .success(try fixture.discovery(includeInitiator: false)),
        ])
        let registry = fixture.registry(broker: broker, clock: clock)
        #expect(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ).isAccepted
        )
        clock.advance(by: 45)

        let lease = try #require(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ).lease
        )
        let closeRecorder = OnlineAdmissionCloseRecorder()
        await registry.monitor(lease, connection: fixture.connection()) { reason in
            await closeRecorder.close(reason: reason)
        }
        // No clock movement: the revalidation runs at once, not 30 s on.
        await closeRecorder.waitUntilClosed()

        #expect(await closeRecorder.observedReasons() == [.denied])
        #expect(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ) == .denied
        )
    }

    @Test
    func aSnapshotOlderThanTheBoundStillWaitsOnTheBroker() async throws {
        let fixture = try OnlineAdmissionFixture(grantLifetime: 3_600)
        let clock = OnlineAdmissionManualClock(now: fixture.now)
        let broker = OnlineAdmissionBroker(responses: [
            .success(try fixture.discovery()),
            .success(try fixture.discovery(includeInitiator: false)),
        ])
        let registry = fixture.registry(broker: broker, clock: clock)
        #expect(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ).isAccepted
        )
        clock.advance(by: 11 * 60)

        #expect(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ) == .denied
        )
        #expect(await broker.callCount() == 2)
    }

    @Test
    func aPairNeverSeenActiveStillWaitsOnTheBroker() async throws {
        let fixture = try OnlineAdmissionFixture(grantLifetime: 3_600)
        let replacement = try fixture.replacementInitiator()
        let clock = OnlineAdmissionManualClock(now: fixture.now)
        let broker = OnlineAdmissionBroker(responses: [
            .success(try fixture.discovery()),
            .success(try fixture.discovery()),
        ])
        let registry = fixture.registry(broker: broker, clock: clock)
        #expect(
            await registry.authorizePairGrant(
                fixture.grant(),
                authenticatedPeerID: fixture.initiator.endpointID
            ).isAccepted
        )
        clock.advance(by: 45)

        // The snapshot does not list this phone: the broker decides, synchronously.
        #expect(
            await registry.authorizePairGrant(
                fixture.grant(initiator: replacement),
                authenticatedPeerID: replacement.endpointID
            ) == .denied
        )
        #expect(await broker.callCount() == 2)
    }
}

actor AdmissionDoneFlag {
    private var value = false
    func set() { value = true }
    func isSet() -> Bool { value }
}
