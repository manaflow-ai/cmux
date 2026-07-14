import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileConnectionLifecyclePersistenceTransactionRegressionTests {
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

private enum ReconnectPersistenceProbeError: Error {
    case loadFailed
}

private actor ReconnectPersistenceProbeState {
    private let failFirstLoadAfterWrite: Bool
    private var hasWritten = false
    private var didFailLoad = false

    init(failFirstLoadAfterWrite: Bool) {
        self.failFirstLoadAfterWrite = failFirstLoadAfterWrite
    }

    func recordWrite() {
        hasWritten = true
    }

    func shouldFailLoad() -> Bool {
        guard failFirstLoadAfterWrite, hasWritten, !didFailLoad else { return false }
        didFailLoad = true
        return true
    }
}

private struct ReconnectPersistenceProbeStore: MobilePairedMacStoring {
    let inner: any MobilePairedMacStoring
    let invalidateAfterWrite: SynchronousGenerationBoundary?
    let state: ReconnectPersistenceProbeState

    init(
        inner: any MobilePairedMacStoring,
        invalidateAfterWrite: SynchronousGenerationBoundary? = nil,
        failFirstLoadAfterWrite: Bool = false
    ) {
        self.inner = inner
        self.invalidateAfterWrite = invalidateAfterWrite
        self.state = ReconnectPersistenceProbeState(
            failFirstLoadAfterWrite: failFirstLoadAfterWrite
        )
    }

    func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        instanceTag: String?,
        markActive: Bool,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        try await inner.upsert(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            instanceTag: instanceTag,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now
        )
        await didWrite()
    }

    func upsertIfNewer(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        instanceTag: String?,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        markActive: Bool,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws -> Bool {
        let wrote = try await inner.upsertIfNewer(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            instanceTag: instanceTag,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now
        )
        if wrote { await didWrite() }
        return wrote
    }

    func upsertRoutesIfAuthorized(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        condition: MobilePairedMacRouteWriteCondition,
        markActive: Bool?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws -> Bool {
        let wrote = try await inner.upsertRoutesIfAuthorized(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            condition: condition,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now
        )
        if wrote { await didWrite() }
        return wrote
    }

    func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        if await state.shouldFailLoad() {
            throw ReconnectPersistenceProbeError.loadFailed
        }
        return try await inner.loadAll(stackUserID: stackUserID, teamID: teamID)
    }

    func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? {
        try await inner.activeMac(stackUserID: stackUserID, teamID: teamID)
    }

    func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        try await inner.setActive(
            macDeviceID: macDeviceID,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    func clearActive(stackUserID: String?, teamID: String?) async throws {
        try await inner.clearActive(stackUserID: stackUserID, teamID: teamID)
    }

    func setCustomization(
        macDeviceID: String,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        try await inner.setCustomization(
            macDeviceID: macDeviceID,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now
        )
    }

    func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        try await inner.remove(
            macDeviceID: macDeviceID,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    func removeAll() async throws {
        try await inner.removeAll()
    }

    private func didWrite() async {
        await state.recordWrite()
        invalidateAfterWrite?.invalidate()
    }
}
