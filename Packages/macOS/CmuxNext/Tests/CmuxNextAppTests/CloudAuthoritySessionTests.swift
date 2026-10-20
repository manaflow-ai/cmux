import Foundation
import Testing
@testable import CmuxNextCloud

@MainActor
@Suite struct CloudAuthoritySessionTests {
    @Test func aDaemonHandshakeCannotRegisterUntilBothOwnerFeedsAreChecked() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let world = CloudAuthoritySessionTestWorld(root: root)
        await world.wire.holdTeamSnapshots()
        let starting = world.lifecycle.update(world.base.identity)
        try await world.wire.waitForConnections(2)
        #expect(throws: (any Error).self) { try world.base.observed.snapshot() }
        #expect(await world.register() == false)
        #expect(world.daemon.registrations == 0)
        try await world.wire.releaseTeamSnapshots()
        await starting.value
        #expect(world.provider.isReady)
        #expect(world.daemon.registrations == 1)
        #expect(try world.base.observed.snapshot().team == CloudTeamScopeWorld.shared)
        await world.stop()
    }

    @Test func remoteLossFencesAHeldStartupBeforeItsHTTPWorkDrains() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let world = CloudAuthoritySessionTestWorld(root: root), identity = world.base.identity
        await world.lifecycle.update(identity).value
        world.holdStartup = true
        let restarting = world.lifecycle.refresh(identity)
        await world.startupGate.waitUntilHeld()
        let old = try world.base.observed.snapshot()
        await world.base.owner.changeAuthority(String(repeating: "b", count: 64))
        try await world.wire.event()
        await world.waitForLoss()
        #expect(!world.provider.isReady)
        #expect(await world.register() == false)
        #expect(world.daemon.registrations == 1)
        await #expect(throws: (any Error).self) { try await old.installToken() }
        await world.startupGate.release()
        await restarting.value
        #expect(world.refused == 1 && world.provider.isReady)
        #expect(world.starts == 3 && world.daemon.registrations == 2)
        #expect(try world.base.observed.snapshot().id != old.id)
        await world.stop()
    }

    @Test func quitDuringInitialScopeLoadingCannotOpenLateFeedsOrCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let world = CloudAuthoritySessionTestWorld(root: root), gate = CloudObservedAuthorityTestGate()
        await world.base.owner.onReply { await gate.hold() }
        let starting = world.lifecycle.update(world.base.identity)
        await gate.waitUntilHeld()
        let stopping = world.lifecycle.stop()
        #expect(!world.provider.isReady)
        await gate.release()
        await starting.value; await stopping.value
        #expect(await world.wire.connections.isEmpty)
        #expect(world.daemon.registrations == 0 && world.starts == 1)
        await world.stop()
    }

    @Test func initialFeedFailureDrainsOnceWithoutAStartupRetryLoop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let world = CloudAuthoritySessionTestWorld(root: root)
        await world.wire.holdTeamSnapshots()
        let starting = world.lifecycle.update(world.base.identity)
        try await world.wire.waitForConnections(2)
        let team = try await world.wire.latest(.team)
        await team.socket.eof()
        await starting.value
        #expect(world.starts == 1 && world.failures == 1)
        #expect(world.daemon.registrations == 0 && !world.provider.isReady)
        #expect(await team.socket.closes == 1)
        await world.stop()
    }

    @Test func explicitPickerChangesRetainTheOriginalRecordWithoutPersonalRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let world = CloudAuthoritySessionTestWorld(root: root), identity = world.base.identity
        await world.lifecycle.update(identity).value
        let old = try world.base.observed.snapshot()
        await world.base.owner.owner.denyPersonalRecovery()
        await world.base.install.invalidate()
        await world.base.owner.select(nil)
        world.authority.selectionChanged(identity, selection: await world.base.owner.selection())
        #expect(!world.provider.isReady)
        await world.lifecycle.update(identity).value
        let next = try world.base.observed.snapshot()
        #expect(next.team == CloudTeamScopeWorld.personal && next.id != old.id)
        #expect(world.provider.isReady)
        #expect(await world.base.owner.owner.registrations == 1)
        await #expect(throws: (any Error).self) { try await old.recheck() }
        await world.stop()
    }

    @Test func localRecordReplacementCannotSilentlyAdoptAnotherInstall() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let world = CloudAuthoritySessionTestWorld(root: root), identity = world.base.identity
        await world.lifecycle.update(identity).value
        let original = try world.base.observed.snapshot()
        world.authority.installChanged(identity, generation: await world.base.install.authorityGeneration)
        #expect(world.provider.isReady && world.losses == 0)
        await world.base.install.invalidate()
        await world.base.owner.owner.denyPersonalRecovery()
        await #expect(throws: (any Error).self) { try await world.base.install.installToken() }
        world.authority.installChanged(identity, generation: await world.base.install.authorityGeneration)
        #expect(!world.provider.isReady)
        await world.lifecycle.update(identity).value
        #expect(throws: (any Error).self) { try world.base.observed.snapshot() }
        #expect(await world.wire.connections.count == 2)
        #expect(await world.base.owner.owner.registrations == 2)
        await #expect(throws: (any Error).self) { try await original.recheck() }
        await world.stop()
    }

    @Test func checkedReconnectKeepsRetryIdentityButRejectsOldCapabilities() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let world = CloudAuthoritySessionTestWorld(root: root), identity = world.base.identity
        await world.lifecycle.update(identity).value
        let old = try world.base.observed.snapshot()
        await world.base.install.invalidate()
        await world.base.owner.owner.denyPersonalRecovery()
        await world.lifecycle.refresh(identity).value
        let next = try world.base.observed.snapshot()
        #expect(next.id == old.id && world.provider.isReady)
        #expect(world.daemon.registrations == 2)
        #expect(await world.base.owner.owner.registrations == 1)
        await #expect(throws: (any Error).self) { try await old.recheck() }
        try await next.recheck()
        await world.stop()
    }

    @Test func oldSessionCallbacksCannotInvalidateANewSessionOfTheSameAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let world = CloudAuthoritySessionTestWorld(root: root), old = world.base.identity
        await world.lifecycle.update(old).value
        world.base.identity = .init(generation: 2, accountID: old.accountID)
        await world.lifecycle.update(world.base.identity).value
        let next = try world.base.observed.snapshot()
        world.authority.selectionChanged(old, selection: nil)
        world.authority.installChanged(old, generation: 0)
        #expect(world.provider.isReady && world.losses == 0 && world.starts == 2)
        try await next.recheck()
        await world.stop()
    }

    @Test func failedInitialAuthorityReadsRetainTheInstallBeforeAnyScopeWasPublished() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let world = CloudAuthoritySessionTestWorld(root: root), identity = world.base.identity
        await world.base.owner.setMode("incomplete")
        await world.lifecycle.update(identity).value
        #expect(world.failures == 1 && !world.provider.isReady)
        #expect(await world.wire.connections.isEmpty)
        await world.base.owner.setMode("valid")
        await world.base.install.invalidate()
        await world.base.owner.owner.denyPersonalRecovery()
        await world.lifecycle.refresh(identity).value
        #expect(world.provider.isReady && world.starts == 2)
        #expect(await world.base.owner.owner.registrations == 1)
        try await world.base.observed.snapshot().recheck()
        await world.stop()
    }
}
