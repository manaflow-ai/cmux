import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileConnectionLifecyclePersistenceTransactionRegressionTests {
    @Test func forgettingUnrelatedMacPreservesOwnedRetiredReconnectDemand() {
        var ownership = MobileConnectionLifecycleTaskOwnership()
        ownership.primaryRetiredReconnectDemand = .macDeviceID("reconnecting-mac")
        ownership.cachedRetiredReconnectDemand = .unresolvedTarget

        ownership.clearRetiredReconnectDemand(forgetting: ["other-mac"])

        #expect(ownership.primaryRetiredReconnectDemand == .macDeviceID("reconnecting-mac"))
        #expect(ownership.cachedRetiredReconnectDemand == .unresolvedTarget)
        #expect(ownership.retiredCarriesReconnectDemand)

        ownership.clearRetiredReconnectDemand(forgetting: ["reconnecting-mac"])

        #expect(ownership.primaryRetiredReconnectDemand == nil)
        #expect(ownership.cachedRetiredReconnectDemand == .unresolvedTarget)
        #expect(ownership.retiredCarriesReconnectDemand)
    }

    @Test func directRollbackRestoresClaimedTeamlessRecordToItsOriginalScope() async throws {
        let (inner, directory) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyRoute = try route(id: "legacy", port: 51_020)
        let reconnectRoute = try route(id: "reconnect", port: 51_021)
        let legacy = storedMac(route: legacyRoute, teamID: nil)
        try await seed(legacy, in: inner)

        let team = MutableTeamID("team-a")
        let scoped = TeamScopedPairedMacStore(
            inner: inner,
            teamIDProvider: { await team.value }
        )
        let fence = SynchronousGenerationBoundary()
        let generation = fence.generation
        let probe = ReconnectPersistenceProbeStore(
            inner: scoped,
            invalidateAfterWrite: fence
        )
        let shell = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: probe,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { await team.value }
        )

        _ = await shell.persistPairedMacFromTicket(
            try ticket(route: reconnectRoute),
            instanceTagUpdate: .replace("default"),
            reconnectSourceMacDeviceID: "mac-a",
            ifStillCurrent: { fence.isCurrent(generation) }
        )

        let restored = try #require(
            try await inner.loadAll(stackUserID: "user-1", teamID: nil)
                .first { $0.macDeviceID == "mac-a" }
        )
        #expect(restored.teamID == nil)
        #expect(restored.routes.map(\.id) == ["legacy"])
        #expect(restored.isActive)
    }

    @Test func deferredRollbackRestoresClaimedTeamlessRecordToItsOriginalScope() async throws {
        let (inner, directory) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyRoute = try route(id: "legacy", port: 51_022)
        let reconnectRoute = try route(id: "reconnect", port: 51_023)
        let legacy = storedMac(route: legacyRoute, teamID: nil)
        try await seed(legacy, in: inner)

        let team = MutableTeamID("team-a")
        let scoped = TeamScopedPairedMacStore(
            inner: inner,
            teamIDProvider: { await team.value }
        )
        let fence = SynchronousGenerationBoundary()
        let generation = fence.generation
        let probe = ReconnectPersistenceProbeStore(
            inner: scoped,
            invalidateAfterWrite: fence
        )
        let operation = DeferredStoredMacReconnectPersistence(
            request: persistenceRequest(
                ticket: try ticket(route: reconnectRoute),
                storedAuthorityMac: legacy
            ),
            store: probe,
            forgottenStore: InMemoryPairedMacForgottenStore(),
            forgottenScopeKeys: [],
            scope: MobileShellScopeSnapshot(
                userID: "user-1",
                teamID: "team-a",
                generation: 0
            ),
            fence: fence,
            fenceGeneration: generation,
            progress: StoredMacReconnectProgress()
        )

        _ = await operation.run()

        let restored = try #require(
            try await inner.loadAll(stackUserID: "user-1", teamID: nil)
                .first { $0.macDeviceID == "mac-a" }
        )
        #expect(restored.teamID == nil)
        #expect(restored.routes.map(\.id) == ["legacy"])
        #expect(restored.isActive)
    }

    @Test func deferredRefreshFailureDoesNotPublishAuthoritativeEmptySnapshot() async throws {
        let (inner, directory) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldRoute = try route(id: "old", port: 51_024)
        let reconnectRoute = try route(id: "reconnect", port: 51_025)
        let existing = storedMac(route: oldRoute, teamID: "team-a")
        try await seed(existing, in: inner)

        let fence = SynchronousGenerationBoundary()
        let probe = ReconnectPersistenceProbeStore(
            inner: inner,
            failFirstLoadAfterWrite: true
        )
        let operation = DeferredStoredMacReconnectPersistence(
            request: persistenceRequest(
                ticket: try ticket(route: reconnectRoute),
                storedAuthorityMac: existing
            ),
            store: probe,
            forgottenStore: InMemoryPairedMacForgottenStore(),
            forgottenScopeKeys: [],
            scope: MobileShellScopeSnapshot(
                userID: "user-1",
                teamID: "team-a",
                generation: 0
            ),
            fence: fence,
            fenceGeneration: fence.generation,
            progress: StoredMacReconnectProgress()
        )

        let result = await operation.run()

        if case .persisted = result {
            Issue.record("a failed refresh must not provide an authoritative paired-Mac snapshot")
        }
        let persisted = try #require(
            try await inner.loadAll(stackUserID: "user-1", teamID: "team-a")
                .first { $0.macDeviceID == "mac-a" }
        )
        #expect(persisted.routes.map(\.id).contains("reconnect"))
    }

    @Test func compensatingBackupRecordIsNewerThanRejectedReconnectWrite() async throws {
        let (inner, directory) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldRoute = try route(id: "old", port: 51_026)
        let reconnectRoute = try route(id: "reconnect", port: 51_027)
        let existing = storedMac(
            route: oldRoute,
            teamID: "team-a",
            lastSeenAt: Date(timeIntervalSince1970: 1_000)
        )
        try await seed(existing, in: inner)

        let team = MutableTeamID("team-a")
        let scoped = TeamScopedPairedMacStore(
            inner: inner,
            teamIDProvider: { await team.value }
        )
        let backup = FakeBackup()
        let backed = BackingUpPairedMacStore(
            inner: scoped,
            backup: backup,
            teamIDProvider: { await team.value }
        )
        let fence = SynchronousGenerationBoundary()
        let generation = fence.generation
        let probe = ReconnectPersistenceProbeStore(
            inner: backed,
            invalidateAfterWrite: fence
        )
        let shell = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: probe,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { await team.value }
        )

        _ = await shell.persistPairedMacFromTicket(
            try ticket(route: reconnectRoute),
            instanceTagUpdate: .replace("default"),
            reconnectSourceMacDeviceID: "mac-a",
            ifStillCurrent: { fence.isCurrent(generation) }
        )

        let uploaded = await backup.uploadedOps().compactMap(uploadedRecord)
        let rejected = try #require(uploaded.dropLast().last)
        let rollback = try #require(uploaded.last)
        #expect(rejected.routes.map(\.id).contains("reconnect"))
        #expect(rollback.routes.map(\.id) == ["old"])
        #expect(rollback.lastSeenAt > rejected.lastSeenAt)
    }

    private func makeInnerStore() throws -> (MobilePairedMacStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (
            try MobilePairedMacStore(
                databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
            ),
            directory
        )
    }

    private func route(id: String, port: Int) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: port)
        )
    }

    private func storedMac(
        route: CmxAttachRoute,
        teamID: String?,
        lastSeenAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: "mac-a",
            displayName: "Original Mac",
            routes: [route],
            createdAt: Date(timeIntervalSince1970: 900),
            lastSeenAt: lastSeenAt,
            isActive: true,
            stackUserID: "user-1",
            teamID: teamID,
            instanceTag: "default"
        )
    }

    private func seed(
        _ mac: MobilePairedMac,
        in store: MobilePairedMacStore
    ) async throws {
        try await store.upsert(
            macDeviceID: mac.macDeviceID,
            displayName: mac.displayName,
            routes: mac.routes,
            instanceTag: mac.instanceTag,
            markActive: mac.isActive,
            stackUserID: mac.stackUserID,
            teamID: mac.teamID,
            now: mac.lastSeenAt
        )
    }

    private func ticket(route: CmxAttachRoute) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "mac-a",
            macDisplayName: "Reconnected Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
    }

    private func persistenceRequest(
        ticket: CmxAttachTicket,
        storedAuthorityMac: MobilePairedMac
    ) -> StoredMacReconnectPersistenceRequest {
        StoredMacReconnectPersistenceRequest(
            ticket: ticket,
            sourceMacDeviceID: "mac-a",
            storedAuthorityMac: storedAuthorityMac,
            displayName: ticket.macDisplayName,
            reportedInstanceTag: "default",
            resolvedInstanceTag: "default"
        )
    }

    private func uploadedRecord(_ op: PairedMacBackupOp) -> PairedMacBackupRecord? {
        switch op {
        case .upsert(let record, _),
             .upsertPreservingCustomizations(let record, _),
             .revive(let record, _),
             .revivePreservingCustomizations(let record, _):
            return record
        case .delete:
            return nil
        }
    }
}
