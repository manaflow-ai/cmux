import CmuxInstallAuthCore
import Foundation
import Testing
@testable import CmuxNextCloud

@Suite struct NativeCloudLinkOwnerTests {
    private func setup(_ root: URL) async throws -> (CloudTeamScopeWorld, CloudTeamScope, NativeCloudLinkOwnerWorld, NativeCloudLinkOwner) {
        let teams = CloudTeamScopeWorld(), world = NativeCloudLinkOwnerWorld()
        let identity = MacInstallIdentity(store: .files(directory: root), transport: teams, deviceName: "Test Mac", clientVersion: "2.4.0")
        try await identity.signedIn(stackUser: "stack_1", session: { "test-session" })
        let scope = CloudTeamScope(identity: identity, transport: teams, selection: { await teams.selection() }, session: { NativeDeviceTestWorld.session() })
        let owner = NativeCloudLinkOwner(make: { await world.make($0) }, invalidate: { await world.note("invalidate") })
        return (teams, scope, world, owner)
    }

    @Test func readsNeverStartAChildAndRepeatedEnsuresReuseOnlyTheCurrentScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, scopes, world, owner) = try await setup(root)
        await owner.resume()
        let scope = try await scopes.snapshot()
        #expect(try await owner.socket(for: scope) == nil)
        #expect(await world.made.isEmpty)
        let socket = try await owner.ensure(scope)
        #expect(try await owner.ensure(scope) == socket)
        #expect(try await owner.socket(for: scope) == socket)
        #expect(await world.made == [CloudTeamScopeWorld.shared])
        await owner.end()
        #expect(try await owner.socket(for: scope) == nil)
        await #expect(throws: NativeDeviceEnrollmentError.signedOut) { try await owner.ensure(scope) }
    }

    @Test func aNewAuthorityRetiresTheOldChildBeforePublishingAndPreservesBothCleanupHandles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (teams, scopes, world, owner) = try await setup(root)
        await owner.resume()
        let first = try await scopes.snapshot()
        _ = try await owner.ensure(first)
        await teams.changeAuthority(String(repeating: "b", count: 64))
        let second = try await scopes.snapshot()
        await #expect(throws: CloudTeamScope.Failure.changed) { try await owner.ensure(first) }
        _ = try await owner.ensure(second)
        await owner.end()
        let events = await world.events, a = String(first.id.prefix(12)), b = String(second.id.prefix(12))
        let oldEnded = try #require(events.firstIndex(of: "stop-finish:\(a)"))
        let newStarted = try #require(events.firstIndex(of: "start:\(b)"))
        #expect(oldEnded < newStarted)
        #expect(events.filter { $0.hasPrefix("revoke:") }.count == 2)
        #expect(try #require(events.firstIndex(of: "invalidate")) < oldEnded)
    }

    @Test func endingDuringStartupJoinsTheChildBeforeRevocationAndNeverPublishesItsSocket() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, scopes, world, owner) = try await setup(root)
        await owner.resume(); await world.holdStartupAndStop()
        let scope = try await scopes.snapshot()
        var started = world.started.stream.makeAsyncIterator(), stopping = world.stopping.stream.makeAsyncIterator()
        // task-owner: start and end; both are joined below after their explicit lifecycle signals.
        let start = Task { try await owner.ensure(scope) }
        let tag = try #require(await started.next())
        let end = Task { await owner.end() }
        #expect(await stopping.next() == tag)
        await #expect(throws: NativeDeviceEnrollmentError.signedOut) { try await owner.ensure(scope) }
        await world.finishStop(tag)
        _ = await start.result
        await end.value
        #expect(try await owner.socket(for: scope) == nil)
        let events = await world.events
        let stopped = try #require(events.firstIndex(of: "stop-finish:\(tag)"))
        let revoked = try #require(events.firstIndex(of: "revoke:\(tag)"))
        #expect(stopped < revoked)
    }
}
