import CmuxInstallAuthCore
import Foundation
import Testing
@testable import CmuxNextCloud

@Suite struct NativeObservedAuthorityTests {
    private func fixture(_ root: URL) async throws -> (NativeDeviceTestWorld, MacInstallIdentity, NativeAuthorityTestScope, NativeDeviceEnrollment) {
        let scope = try NativeDeviceScope(team: NativeDeviceTestWorld.team("tenant_a"), tenant: "tenant_a",
            mesh: "mesh_" + String(repeating: "0", count: 26))
        let world = NativeDeviceTestWorld(scopes: [scope])
        let identity = MacInstallIdentity(store: .files(directory: root.appendingPathComponent("install")),
            transport: world, deviceName: "Test Mac", clientVersion: "2.4.0")
        try await identity.signedIn(stackUser: "stack_1", session: { "test-session" })
        let authority = NativeAuthorityTestScope(try await identity.nativeContext(team: scope.team))
        let enrollment = try NativeDeviceEnrollment(scope: scope, identity: identity,
            paths: CloudPaths(root: root.appendingPathComponent("networks")), native: world,
            session: { NativeDeviceTestWorld.session() }, name: "Test Mac",
            context: { try await authority.load() }, recheck: { try await authority.check() })
        return (world, identity, authority, enrollment)
    }

    @Test func startupAndBrokerRefreshReuseThePinnedInstallWithoutPersonalRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (world, identity, authority, device) = try await fixture(root)
        _ = try await device.enroll()
        await identity.invalidate()
        await world.auth.denyPersonalRecovery()
        let startup = try await device.linkStartup()
        try await startup.recheck()
        let request = Data(#"{"version":1,"id":1,"op":"cloud.machine.connect_info","host":"host_11111111111111111111"}"#.utf8)
        _ = try await device.cloudBrokerReply(request)
        #expect(await authority.loads == 3)
        #expect(await world.auth.registrations == 1)
        #expect(await world.enrollments == 1)
        #expect(await world.tunnelReads == 1)
        await device.stop()
    }

    @Test func lossDuringEnrollmentRefusesBindingButRetainsOriginalAccountCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (world, _, authority, device) = try await fixture(root)
        await world.onPolicy { await authority.lose() }
        await #expect(throws: CloudTeamScope.Failure.changed) { try await device.enroll() }
        #expect(await world.enrollments == 1)
        #expect(await world.binds == 0)
        try await device.revoke()
        #expect(await world.deletions == 1)
        await #expect(throws: NativeDeviceEnrollmentError.revoked) { try await device.enroll() }
    }

    @Test func lossDuringBrokerMintCannotReturnTheOldTokenOrStartupKey() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (world, _, authority, device) = try await fixture(root)
        let startup = try await device.linkStartup()
        await world.onCloud { await authority.lose() }
        let request = Data(#"{"version":1,"id":1,"op":"cloud.machine.link_token","host":"host_11111111111111111111","services":["ssh"]}"#.utf8)
        await #expect(throws: CloudTeamScope.Failure.changed) { try await device.cloudBrokerReply(request) }
        await #expect(throws: CloudTeamScope.Failure.changed) { try await startup.recheck() }
        #expect(await world.cloudMints == 1)
        try await device.revoke()
        #expect(await world.deletions == 1)
    }
}
