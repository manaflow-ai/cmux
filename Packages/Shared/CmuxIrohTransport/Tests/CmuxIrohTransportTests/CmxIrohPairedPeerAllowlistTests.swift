import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohPairedPeerAllowlistTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func scope(
        accountID: String = "acct-1",
        appInstanceID: String = "123e4567-e89b-42d3-a456-426614174005"
    ) -> CmxIrohPairedPeerAllowlistScope {
        CmxIrohPairedPeerAllowlistScope(
            accountID: accountID,
            clientNamespace: "com.cmuxterm.dev",
            appInstanceID: appInstanceID
        )
    }

    private func entry(
        fixture: OnlineAdmissionFixture,
        lifetime: TimeInterval = 3_600
    ) -> CmxIrohPairedPeerAllowlistEntry {
        CmxIrohPairedPeerAllowlistEntry(
            initiator: fixture.initiator,
            acceptor: fixture.acceptor,
            expiresAt: now.addingTimeInterval(lifetime),
            recordedAt: now
        )
    }

    @Test
    func recordedEntryRoundTripsThroughPersistence() async throws {
        let fixture = try OnlineAdmissionFixture()
        let store = TestSecureCredentialStore()
        let scope = scope()
        await CmxIrohPairedPeerAllowlist(secureStore: store).record(
            entry(fixture: fixture),
            scope: scope,
            now: now
        )

        // A fresh instance over the same store proves relaunch durability.
        let reloaded = CmxIrohPairedPeerAllowlist(secureStore: store)
        let found = await reloaded.entry(
            forInitiatorEndpointID: fixture.initiator.endpointID,
            scope: scope,
            now: now
        )
        #expect(found?.initiator == fixture.initiator)
        #expect(found?.acceptor == fixture.acceptor)
    }

    @Test
    func scopeMismatchIsAMissAndDropsForeignEntries() async throws {
        let fixture = try OnlineAdmissionFixture()
        let store = TestSecureCredentialStore()
        await CmxIrohPairedPeerAllowlist(secureStore: store).record(
            entry(fixture: fixture),
            scope: scope(accountID: "acct-1"),
            now: now
        )

        let otherAccount = CmxIrohPairedPeerAllowlist(secureStore: store)
        let found = await otherAccount.entry(
            forInitiatorEndpointID: fixture.initiator.endpointID,
            scope: scope(accountID: "acct-2"),
            now: now
        )
        #expect(found == nil)
        // The prior account's entries must not survive into the new scope.
        let back = await otherAccount.entry(
            forInitiatorEndpointID: fixture.initiator.endpointID,
            scope: scope(accountID: "acct-1"),
            now: now
        )
        #expect(back == nil)
    }

    @Test
    func expiredEntryIsAMissAndIsDeleted() async throws {
        let fixture = try OnlineAdmissionFixture()
        let store = TestSecureCredentialStore()
        let allowlist = CmxIrohPairedPeerAllowlist(secureStore: store)
        let scope = scope()
        await allowlist.record(
            entry(fixture: fixture, lifetime: 60),
            scope: scope,
            now: now
        )

        let afterExpiry = now.addingTimeInterval(120)
        let found = await allowlist.entry(
            forInitiatorEndpointID: fixture.initiator.endpointID,
            scope: scope,
            now: afterExpiry
        )
        #expect(found == nil)
        let again = await allowlist.entry(
            forInitiatorEndpointID: fixture.initiator.endpointID,
            scope: scope,
            now: now
        )
        #expect(again == nil)
    }

    @Test
    func revokedInitiatorBindingIsRemoved() async throws {
        let fixture = try OnlineAdmissionFixture()
        let allowlist = CmxIrohPairedPeerAllowlist(
            secureStore: TestSecureCredentialStore()
        )
        let scope = scope()
        await allowlist.record(entry(fixture: fixture), scope: scope, now: now)
        await allowlist.removeEntries(
            bindingID: fixture.initiator.bindingID,
            scope: scope
        )
        let found = await allowlist.entry(
            forInitiatorEndpointID: fixture.initiator.endpointID,
            scope: scope,
            now: now
        )
        #expect(found == nil)
    }

    @Test
    func revokedAcceptorBindingClearsItsEntries() async throws {
        let fixture = try OnlineAdmissionFixture()
        let allowlist = CmxIrohPairedPeerAllowlist(
            secureStore: TestSecureCredentialStore()
        )
        let scope = scope()
        await allowlist.record(entry(fixture: fixture), scope: scope, now: now)
        await allowlist.removeEntries(
            bindingID: fixture.acceptor.bindingID,
            scope: scope
        )
        let found = await allowlist.entry(
            forInitiatorEndpointID: fixture.initiator.endpointID,
            scope: scope,
            now: now
        )
        #expect(found == nil)
    }

    @Test
    func deactivateRemovesEverything() async throws {
        let fixture = try OnlineAdmissionFixture()
        let store = TestSecureCredentialStore()
        let allowlist = CmxIrohPairedPeerAllowlist(secureStore: store)
        let scope = scope()
        await allowlist.record(entry(fixture: fixture), scope: scope, now: now)
        try await allowlist.deactivate()
        let found = await CmxIrohPairedPeerAllowlist(secureStore: store).entry(
            forInitiatorEndpointID: fixture.initiator.endpointID,
            scope: scope,
            now: now
        )
        #expect(found == nil)
    }
}
