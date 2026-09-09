import CmuxMobileShell
import Foundation
import Testing
@testable import CmuxHive

@MainActor
struct HiveDirectoryScopeTests {
    @Test(.timeLimit(.minutes(1)))
    func scopeReadCannotRevalidateAnOperationAfterSignOut() async throws {
        let scope = HiveAccountScope(stackUserID: "user-1", teamID: "team-1")
        let gate = HiveScopeReadGate(scope: scope)
        let (store, cleanup) = try HiveDirectoryTestFixture().makeTempStore()
        defer { cleanup() }
        let directory = HiveComputerDirectory(
            registry: HiveDirectoryTestFixture.Registry(outcome: .ok([])),
            pairedStore: store, presence: nil, ownDeviceID: "self-device",
            scopeProvider: { await gate.read() },
            linkDecoder: HivePairingLinkDecoder(allowsLoopbackRoutes: false),
            presenceRetryDelay: { _ in }
        )
        await directory.refresh()
        let generation = directory.scopeGeneration
        await gate.holdNextRead()
        let validation = Task { await directory.isCurrentScope(scope, generation: generation) }
        var started = gate.started.stream.makeAsyncIterator()
        _ = try #require(await started.next())

        directory.clearForSignOut()
        await gate.changeScope(to: HiveAccountScope(stackUserID: nil, teamID: nil))
        await gate.finishCapturedRead()

        #expect(await validation.value == false)
    }

    @Test func obsoletePairingReloadCannotResurrectSignedOutRows() async throws {
        let fixture = HiveDirectoryTestFixture()
        let (store, cleanup) = try fixture.makeTempStore()
        defer { cleanup() }
        try await store.upsert(
            macDeviceID: "private-mac", displayName: "Private Mac",
            routes: [try fixture.tailscaleRoute()], instanceTag: nil, markActive: false,
            stackUserID: "user-1", teamID: "team-1", now: Date()
        )
        let directory = fixture.makeDirectory(registry: .ok([]), store: store)
        await directory.refresh()
        try #require(directory.computers.count == 1)
        directory.clearForSignOut()

        await directory.reloadPairedRecords(scope: HiveAccountScope(stackUserID: "user-1", teamID: "team-1"))
        // Presence invalidation uses this same projection after a stale operation returns.
        directory.rebuild()

        #expect(directory.computers.isEmpty)
    }
}
