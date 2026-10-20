import CmuxInstallAuthCore
import Foundation
import Testing
@testable import CmuxNextCloud

@Suite struct CloudAuthorityScopeTests {
    private func setup(_ root: URL) async throws -> (CloudTeamScopeWorld, CloudTeamScope) {
        let world = CloudTeamScopeWorld()
        let identity = MacInstallIdentity(store: .files(directory: root), transport: world, deviceName: "Test Mac", clientVersion: "2.4.0")
        try await identity.signedIn(stackUser: "stack_1", session: { "test-session" })
        return (world, CloudTeamScope(identity: identity, transport: world,
            selection: { await world.selection() }, session: { NativeDeviceTestWorld.session() }))
    }

    @Test func currentAuthorityChangesInvalidateSnapshotsAndReplayIDs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (world, resolver) = try await setup(root)
        let first = try await resolver.snapshot()
        await world.changeAuthority(String(repeating: "b", count: 64))
        await #expect(throws: CloudTeamScope.Failure.changed) { try await first.recheck() }
        await #expect(throws: CloudTeamScope.Failure.changed) { try await first.sessionToken() }
        let next = try await resolver.snapshot()
        #expect(next.team == first.team && next.id != first.id)
    }

    @Test(arguments: ["missing", "null", "user", "team", "install", "grant", "revoked"])
    func unverifiableAuthorityCannotStartASnapshot(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (world, resolver) = try await setup(root)
        await world.setAuthorityMode(mode)
        await #expect(throws: (any Error).self) { _ = try await resolver.snapshot() }
        #expect(await world.operationTeams.isEmpty)
    }

    @Test func anAuthorityChangeBeforeAnApprovalStepPreventsItsDispatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (world, resolver) = try await setup(root)
        let snapshot = try await resolver.snapshot()
        await world.changeAuthority(String(repeating: "b", count: 64))
        await #expect(throws: CloudTeamScope.Failure.changed) {
            _ = try await snapshot.call("/v1/ops", Data(#"{"op":"feed.answer","params":{}}"#.utf8))
        }
        #expect(await world.operationTeams.isEmpty)
    }

    @Test func anAuthorityChangeDuringAnApprovalStepDiscardsItsResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (world, resolver) = try await setup(root)
        let snapshot = try await resolver.snapshot()
        await world.onOperationReply { await world.changeAuthority(String(repeating: "b", count: 64)) }
        await #expect(throws: CloudTeamScope.Failure.changed) {
            _ = try await snapshot.call("/v1/ops", Data(#"{"op":"feed.answer","params":{}}"#.utf8))
        }
        #expect(await world.operationTeams == [CloudTeamScopeWorld.shared])
    }

    @Test func completionChecksReadOnlyTheTargetedAuthority() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (world, resolver) = try await setup(root)
        let snapshot = try await resolver.snapshot()
        try await snapshot.recheck()
        try await snapshot.recheck()
        #expect(await world.listings == 1)
        #expect(await world.authorityReads == 3)
        #expect(await world.owner.requestedTeams == [CloudTeamScopeWorld.shared])
    }
}
