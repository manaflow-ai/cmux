import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

/// Mac-side allowlist admission: a grant-verified pairing is persisted once,
/// later connections are admitted from the TLS-proven EndpointID with no
/// admission credential, and revocation or registry removal evicts the entry.
@Suite
struct CmxIrohPairedPeerAdmissionTests {
    private struct Harness {
        let fixture: OnlineAdmissionFixture
        let broker: OnlineAdmissionBroker
        let store: TestSecureCredentialStore
        let allowlist: CmxIrohPairedPeerAllowlist
        let scope: CmxIrohPairedPeerAllowlistScope
        let clock: OnlineAdmissionManualClock
        let controller: CmxIrohAdmissionController

        init(
            fixture: OnlineAdmissionFixture,
            responses: [Result<CmxIrohDiscoveryResponse, CmxIrohTrustBrokerClientError>],
            store: TestSecureCredentialStore = TestSecureCredentialStore()
        ) {
            self.fixture = fixture
            self.store = store
            broker = OnlineAdmissionBroker(responses: responses)
            allowlist = CmxIrohPairedPeerAllowlist(secureStore: store)
            scope = CmxIrohPairedPeerAllowlistScope(
                accountID: "account-a",
                clientNamespace: "com.cmuxterm.dev",
                appInstanceID: "123e4567-e89b-42d3-a456-426614174005"
            )
            let clock = OnlineAdmissionManualClock(now: fixture.now)
            self.clock = clock
            controller = CmxIrohAdmissionController(
                acceptor: fixture.acceptor,
                pairingEnabled: true,
                offlineSessions: CmxIrohOfflinePairingSessions(pairingEnabled: true),
                onlineRegistry: fixture.registry(broker: broker, clock: clock),
                allowlist: allowlist,
                allowlistScope: scope,
                now: { clock.now() }
            )
        }
    }

    @Test
    func verifiedGrantRecordsAllowlistEntryAndAdmitsLaterWithoutCredential() async throws {
        let fixture = try OnlineAdmissionFixture()
        let harness = Harness(
            fixture: fixture,
            responses: [
                .success(try fixture.discovery()),
                .success(try fixture.discovery()),
            ]
        )

        // Bootstrap: in-band pair grant, verified and admitted.
        let bootstrap = await harness.controller.authorize(
            credential: try .pairGrant(fixture.grant()),
            authenticatedPeerID: fixture.initiator.endpointID
        )
        guard case let .accepted(peer, _) = bootstrap else {
            Issue.record("bootstrap grant admission was denied")
            return
        }
        #expect(peer == CmxIrohAdmittedPeer(peer: fixture.initiator))
        let recorded = await harness.allowlist.entry(
            forInitiatorEndpointID: fixture.initiator.endpointID,
            scope: harness.scope,
            now: fixture.now
        )
        #expect(recorded?.initiator == fixture.initiator)
        #expect(recorded?.acceptor == fixture.acceptor)

        // Transition: the next connection presents NO credential and is
        // admitted purely from the proven EndpointID via the allowlist.
        let warm = await harness.controller.authorize(
            credential: nil,
            authenticatedPeerID: fixture.initiator.endpointID
        )
        guard case let .accepted(warmPeer, warmLease) = warm else {
            Issue.record("allowlist admission was denied")
            return
        }
        #expect(warmPeer == CmxIrohAdmittedPeer(peer: fixture.initiator))
        #expect(warmLease != nil)
    }

    @Test
    func allowlistAdmissionSurvivesControllerRelaunch() async throws {
        let fixture = try OnlineAdmissionFixture()
        let store = TestSecureCredentialStore()
        let first = Harness(
            fixture: fixture,
            responses: [.success(try fixture.discovery())],
            store: store
        )
        _ = await first.controller.authorize(
            credential: try .pairGrant(fixture.grant()),
            authenticatedPeerID: fixture.initiator.endpointID
        )

        // A fresh controller + allowlist over the same secure store models a
        // Mac relaunch: the pairing survives with no new credential needed.
        let second = Harness(
            fixture: fixture,
            responses: [.success(try fixture.discovery())],
            store: store
        )
        let warm = await second.controller.authorize(
            credential: nil,
            authenticatedPeerID: fixture.initiator.endpointID
        )
        guard case .accepted = warm else {
            Issue.record("allowlist admission after relaunch was denied")
            return
        }
    }

    @Test
    func strangerProvenKeyWithoutCredentialIsRefused() async throws {
        let fixture = try OnlineAdmissionFixture()
        let harness = Harness(
            fixture: fixture,
            responses: [.success(try fixture.discovery())]
        )
        // A cryptographically proven but never-paired EndpointID gets no
        // admission without a credential.
        let stranger = try fixture.replacementInitiator()
        let refused = await harness.controller.authorize(
            credential: nil,
            authenticatedPeerID: stranger.endpointID
        )
        #expect(refused == .denied(code: 1))
        // No broker round is spent on a stranger's credential-less attempt.
        #expect(await harness.broker.callCount() == 0)
    }

    @Test
    func revokedPairingIsRefusedWithoutCredentialAndWithStaleGrant() async throws {
        let fixture = try OnlineAdmissionFixture()
        let harness = Harness(
            fixture: fixture,
            responses: [
                .success(try fixture.discovery()),
                .success(try fixture.discovery()),
                .success(try fixture.discovery()),
            ]
        )
        let staleGrant = fixture.grant()
        _ = await harness.controller.authorize(
            credential: try .pairGrant(staleGrant),
            authenticatedPeerID: fixture.initiator.endpointID
        )

        // Unpair: local revoke of the phone binding.
        await harness.controller.revoke(bindingID: fixture.initiator.bindingID)

        let warm = await harness.controller.authorize(
            credential: nil,
            authenticatedPeerID: fixture.initiator.endpointID
        )
        #expect(warm == .denied(code: 1))
        // The allowlist entry is gone, not just ignored.
        let entry = await harness.allowlist.entry(
            forInitiatorEndpointID: fixture.initiator.endpointID,
            scope: harness.scope,
            now: fixture.now
        )
        #expect(entry == nil)

        // The evicted key stays refused even when it replays its stale,
        // still-signed cached grant.
        let replay = await harness.controller.authorize(
            credential: try .pairGrant(staleGrant),
            authenticatedPeerID: fixture.initiator.endpointID
        )
        #expect(replay == .denied(code: 1))
    }

    @Test
    func registryRemovalEvictsAllowlistEntryOnRevalidation() async throws {
        let fixture = try OnlineAdmissionFixture(grantLifetime: 600)
        let harness = Harness(
            fixture: fixture,
            responses: [
                .success(try fixture.discovery()),
                // After the unpair, the broker no longer lists the phone.
                .success(try fixture.discovery(includeInitiator: false)),
            ]
        )
        _ = await harness.controller.authorize(
            credential: try .pairGrant(fixture.grant()),
            authenticatedPeerID: fixture.initiator.endpointID
        )

        // Age the cached broker snapshot past its 30s reuse window so the
        // next admission must revalidate against the post-unpair registry.
        harness.clock.advance(by: 31)

        let warm = await harness.controller.authorize(
            credential: nil,
            authenticatedPeerID: fixture.initiator.endpointID
        )
        #expect(warm == .denied(code: 1))
        let entry = await harness.allowlist.entry(
            forInitiatorEndpointID: fixture.initiator.endpointID,
            scope: harness.scope,
            now: harness.clock.now()
        )
        #expect(entry == nil)
    }

    @Test
    func acceptorIdentityChangeInvalidatesEntries() async throws {
        let fixture = try OnlineAdmissionFixture()
        let harness = Harness(
            fixture: fixture,
            responses: [
                .success(try fixture.discovery()),
                .success(try fixture.discovery()),
            ]
        )
        _ = await harness.controller.authorize(
            credential: try .pairGrant(fixture.grant()),
            authenticatedPeerID: fixture.initiator.endpointID
        )

        // The Mac re-registered under a new binding: entries pinned to the
        // old acceptor tuple must not admit anyone.
        await harness.controller.update(
            keys: fixture.keySet,
            acceptor: fixture.replacementAcceptor(),
            pairingEnabled: true
        )
        let warm = await harness.controller.authorize(
            credential: nil,
            authenticatedPeerID: fixture.initiator.endpointID
        )
        #expect(warm == .denied(code: 1))
        let entry = await harness.allowlist.entry(
            forInitiatorEndpointID: fixture.initiator.endpointID,
            scope: harness.scope,
            now: fixture.now
        )
        #expect(entry == nil)
    }

    @Test
    func pairingDisabledRefusesAllowlistAdmission() async throws {
        let fixture = try OnlineAdmissionFixture()
        let harness = Harness(
            fixture: fixture,
            responses: [
                .success(try fixture.discovery()),
                .success(try fixture.discovery()),
            ]
        )
        _ = await harness.controller.authorize(
            credential: try .pairGrant(fixture.grant()),
            authenticatedPeerID: fixture.initiator.endpointID
        )
        await harness.controller.update(
            keys: fixture.keySet,
            acceptor: fixture.acceptor,
            pairingEnabled: false
        )
        let warm = await harness.controller.authorize(
            credential: nil,
            authenticatedPeerID: fixture.initiator.endpointID
        )
        #expect(warm == .denied(code: 1))
    }
}
