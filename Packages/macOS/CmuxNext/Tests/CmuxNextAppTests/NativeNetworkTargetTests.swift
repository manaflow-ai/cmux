import CmuxInstallAuthCore
import CmuxNextCloud
import Foundation
import Testing

@Suite struct NativeNetworkTargetTests {
    private func fixture(root: URL) async throws -> (NativeDeviceScope, NativeDeviceTestWorld, MacInstallIdentity) {
        let scope = try NativeDeviceScope(team: NativeDeviceTestWorld.team("tenant_a"), tenant: "tenant_a", mesh: "mesh_" + String(repeating: "0", count: 26))
        let world = NativeDeviceTestWorld(scopes: [scope])
        let identity = MacInstallIdentity(store: .files(directory: root.appendingPathComponent("install")), transport: world, deviceName: "Test Mac", clientVersion: "2.4.0")
        try await identity.signedIn(stackUser: "stack_1", session: { "test-session" })
        return (scope, world, identity)
    }

    @Test(arguments: [false, true])
    func discoversThroughOriginalOwnerAndFeedsVerifiedEnrollment(explicit: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (scope, world, identity) = try await fixture(root: root)
        let target = try await identity.nativeNetworkTarget(team: scope.team, mesh: explicit ? scope.mesh : nil)
        #expect(target.scope == scope)
        #expect(target.origin == world.origin && target.project == NativeDeviceTestWorld.project)
        #expect(target.ipv4CIDR == "10.128.0.0/20")
        #expect(await world.enrollments == 0)
        #expect(await world.binds == 0)
        let enrollment = try NativeDeviceEnrollment(scope: target.scope, identity: identity, paths: CloudPaths(root: root.appendingPathComponent("network")), native: world,
                                                    session: { NativeDeviceTestWorld.session() }, name: "Test Mac")
        let binding = try await enrollment.enroll()
        #expect(binding.team == scope.team && binding.mesh == scope.mesh && binding.tenant == scope.tenant)
        #expect(await world.enrollments == 1)
        #expect(await world.binds == 1)
        #expect(await world.auth.registrations == 1)
    }

    @Test(arguments: ["team", "tenant", "project", "mesh", "origin", "ipv4_cidr"])
    func rejectsAConflictingOwnerReply(field: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (scope, world, identity) = try await fixture(root: root)
        await world.setBadTarget(field)
        await #expect(throws: (any Error).self) { try await identity.nativeNetworkTarget(team: scope.team, mesh: scope.mesh) }
        #expect(await world.enrollments == 0)
    }

    @Test func signOutDuringDiscoveryNeverReturnsTheOldAccountsTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (scope, world, identity) = try await fixture(root: root)
        await world.onTarget { await identity.unbind() }
        await #expect(throws: MacInstallIdentity.Failure.signedOut) { try await identity.nativeNetworkTarget(team: scope.team) }
        #expect(await world.enrollments == 0)
    }

    @Test func malformedSelectorsNeverMintATokenOrReadTheOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (scope, world, identity) = try await fixture(root: root)
        let before = await world.requests.count
        await #expect(throws: NativeDeviceEnrollmentError.invalidScope) { try await identity.nativeNetworkTarget(team: scope.team, mesh: "../other") }
        #expect(await world.requests.count == before)
        #expect(await world.auth.requestedTeams.isEmpty)
    }

    @Test func ownerRefusalDoesNotFallBackToAnotherMeshOrCreateADevice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (scope, world, identity) = try await fixture(root: root)
        await world.refuseTarget(503)
        await #expect(throws: NativeDeviceEnrollmentError.refused(503)) { try await identity.nativeNetworkTarget(team: scope.team) }
        #expect(await world.enrollments == 0)
        #expect(await world.auth.requestedTeams == [scope.team])
    }
}
