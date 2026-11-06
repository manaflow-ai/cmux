import CmuxInstallAuthCore
import Foundation
import Testing
@testable import CmuxNextCloud

@Suite struct NativeCloudBrokerTests {
    private let host = "host_11111111111111111111"

    private func fixture(root: URL) async throws -> (NativeDeviceScope, NativeDeviceTestWorld, MacInstallIdentity, NativeDeviceEnrollment) {
        let scope = try NativeDeviceScope(team: NativeDeviceTestWorld.team("tenant_a"), tenant: "tenant_a", mesh: "mesh_" + String(repeating: "0", count: 26))
        let world = NativeDeviceTestWorld(scopes: [scope])
        let identity = MacInstallIdentity(store: .files(directory: root.appendingPathComponent("install")), transport: world, deviceName: "Test Mac", clientVersion: "2.4.0")
        try await identity.signedIn(stackUser: "stack_1", session: { "test-session" })
        let device = try NativeDeviceEnrollment(scope: scope, identity: identity, paths: CloudPaths(root: root.appendingPathComponent("networks")),
                                                native: world, session: { NativeDeviceTestWorld.session() }, name: "Test Mac")
        return (scope, world, identity, device)
    }

    private func mint(_ id: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": 1, "id": id, "op": "cloud.machine.link_token", "host": host, "services": ["ssh"]])
    }
    private func object(_ bytes: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    @Test func eachMintUsesTheExplicitTeamAndAFreshInstallProof() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (scope, world, identity, device) = try await fixture(root: root)
        let first = try object(await device.cloudBrokerReply(mint(1)))
        let second = try object(await device.cloudBrokerReply(mint(2)))
        #expect(first["id"] as? Int == 1 && second["id"] as? Int == 2)
        #expect((first["value"] as? [String: Any])?["token"] as? String == "dial-once-1")
        #expect((second["value"] as? [String: Any])?["token"] as? String == "dial-once-2")
        #expect(await world.cloudMints == 2)
        #expect(await world.enrollments == 1)
        let nonces = await world.proofNonces
        #expect(nonces.count == 5 && Set(nonces).count == 5)
        #expect(await world.auth.requestedTeams.allSatisfy { $0 == scope.team })
        #expect(await world.auth.registrations == 1)
        #expect(await identity.installID() == "inst_1")
    }

    @Test func aReadDoesNotMintOrForwardAccountCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, world, _, device) = try await fixture(root: root)
        let request = try JSONSerialization.data(withJSONObject: ["version": 1, "id": 1, "op": "cloud.machine.connect_info", "host": host])
        let reply = try object(await device.cloudBrokerReply(request))
        #expect((reply["value"] as? [String: Any])?["host"] as? String == host)
        #expect(await world.cloudMints == 0)
        #expect(reply["version"] as? Int == 1 && reply.count == 3)
        let encoded = try JSONSerialization.data(withJSONObject: reply)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("stack_1"))
    }

    @Test func signOutWhileMintingNeverReturnsTheOldToken() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, world, identity, device) = try await fixture(root: root)
        await world.onCloud { await identity.unbind() }
        await #expect(throws: MacInstallIdentity.Failure.signedOut) { try await device.cloudBrokerReply(mint(1)) }
        #expect(await world.cloudMints == 1)
    }

    @Test func deniedSharedTeamDoesNotFallBackToPersonalCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (scope, world, _, device) = try await fixture(root: root)
        await world.auth.deny(scope.team)
        await #expect(throws: InstallAuthError.refused("auth.forbidden")) { try await device.cloudBrokerReply(mint(1)) }
        #expect(await world.cloudMints == 0)
        #expect(await world.enrollments == 0)
    }

    @Test func aMissingDeviceCheckpointDoesNotCreateAReplacementKey() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, world, _, device) = try await fixture(root: root)
        _ = try await device.cloudBrokerReply(mint(1))
        let files = FileManager.default.enumerator(at: root.appendingPathComponent("networks"), includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        let checkpoint = try #require(files.first { $0.lastPathComponent == "identity.json" })
        try FileManager.default.removeItem(at: checkpoint)
        await #expect(throws: (any Error).self) { try await device.cloudBrokerReply(mint(2)) }
        #expect(!FileManager.default.fileExists(atPath: checkpoint.path))
        #expect(await world.cloudMints == 1)
        #expect(await world.enrollments == 1)
    }

    @Test func theStartupKeyMatchesTheEnrolledMeshAndStopsAfterScopeEnd() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (scope, _, _, device) = try await fixture(root: root)
        let joined = try await device.enroll(), startup = try await device.linkStartup()
        let value = try object(startup.bytes)
        #expect(value["team"] as? String == scope.team && value["mesh"] as? String == scope.mesh)
        #expect(startup.publicKey == joined.wgPublicKey)
        try await startup.recheck()
        await device.stop()
        await #expect(throws: NativeDeviceEnrollmentError.revoked) { try await startup.recheck() }
        #expect(!String(reflecting: startup).contains(value["private_key"] as? String ?? "missing"))
    }

    @Test(arguments: ["team", "url", "native_proof", "origin"])
    func callerCannotChooseAuthority(field: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, world, _, device) = try await fixture(root: root)
        var request = try object(mint(1)); request[field] = "attacker-choice"
        let bytes = try JSONSerialization.data(withJSONObject: request), before = await world.requests.count
        await #expect(throws: (any Error).self) { try await device.cloudBrokerReply(bytes) }
        #expect(await world.requests.count == before)
    }

    @Test func everyStartupGetsAFreshSignedTunnelWithoutSendingAccountCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (scope, world, _, device) = try await fixture(root: root)
        let first = try await device.linkStartup(), second = try await device.linkStartup()
        #expect(await world.tunnelReads == 2)
        let nonces = await world.proofNonces
        #expect(nonces.count == 7 && Set(nonces).count == 7)
        let startup = try object(second.bytes)
        #expect(startup["version"] as? Int == 2 && startup["tenant"] as? String == scope.tenant)
        #expect(startup["ipv4_cidr"] as? String == "10.128.0.0/20")
        #expect((startup["tunnel"] as? [String: Any])?["meshId"] as? String == scope.mesh)
        #expect(first.publicKey == second.publicKey)
        #expect(await world.enrollments == 1)
    }

    @Test(arguments: ["deviceId", "meshId"])
    func aTunnelForAnotherDeviceOrMeshCannotBecomeStartupAuthority(field: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, world, _, device) = try await fixture(root: root)
        await world.setBadTunnel(field)
        await #expect(throws: (any Error).self) { try await device.linkStartup() }
        #expect(await world.tunnelReads == 1)
    }

    @Test func signOutWhileReadingATunnelNeverReturnsTheStartupKey() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, world, identity, device) = try await fixture(root: root)
        await world.onTunnel { await identity.unbind() }
        await #expect(throws: MacInstallIdentity.Failure.signedOut) { try await device.linkStartup() }
        #expect(await world.tunnelReads == 1)
    }
}
