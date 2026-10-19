import CmuxInstallAuthCore
import CmuxNextCloud
import Foundation
import Testing

@Suite struct NativeDeviceEnrollmentTests {
    private func makeScope(_ letter: String = "a", mesh: String = "0") throws -> NativeDeviceScope {
        try NativeDeviceScope(team: NativeDeviceTestWorld.team("tenant_\(letter)"), tenant: "tenant_\(letter)", mesh: "mesh_" + String(repeating: mesh, count: 26))
    }
    private func setup(_ scopes: [NativeDeviceScope], root: URL) async throws -> (NativeDeviceTestWorld, MacInstallIdentity) {
        let world = NativeDeviceTestWorld(scopes: scopes)
        let identity = MacInstallIdentity(store: .files(directory: root.appendingPathComponent("install")), transport: world, deviceName: "Test Mac", clientVersion: "2.4.0")
        try await identity.signedIn(stackUser: "stack_1", session: { "test-session" })
        return (world, identity)
    }
    private func client(_ scope: NativeDeviceScope, world: NativeDeviceTestWorld, identity: MacInstallIdentity, root: URL,
                        session: @escaping InstallAuthClient.SessionToken = { NativeDeviceTestWorld.session() }) throws -> NativeDeviceEnrollment {
        try NativeDeviceEnrollment(scope: scope, identity: identity, paths: CloudPaths(root: root.appendingPathComponent("networks")), native: world, session: session, name: "Test Mac")
    }
    private func records(_ root: URL) -> [URL] {
        let list = FileManager.default.enumerator(at: root.appendingPathComponent("networks"), includingPropertiesForKeys: nil)
        return (list?.allObjects as? [URL] ?? []).filter { $0.lastPathComponent == "identity.json" }
    }

    @Test func verifiesBothAuthoritiesWithFreshProofsAndPersistsOnlyItsPrivateKeyAndLocator() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try makeScope(), (world, identity) = try await setup([scope], root: root)
        let joined = try await client(scope, world: world, identity: identity, root: root).enroll()
        #expect(joined.team == scope.team && joined.tenant == scope.tenant && joined.mesh == scope.mesh)
        #expect(await world.enrollments == 1)
        #expect(await world.binds == 1)
        #expect(await world.signedReadsWithCredentials == 0)
        let nonces = await world.proofNonces
        #expect(nonces.count == 3 && Set(nonces).count == 3) // Enroll, direct policy read, backend policy read.
        let files = records(root)
        #expect(files.count == 1)
        let bytes = try Data(contentsOf: #require(files.first)), saved = String(decoding: bytes, as: UTF8.self)
        let json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: String])
        #expect(json["device"] == joined.device)
        for forbidden in ["access_token", "signature", "nonce", "accountCredential", "must-not-persist-policy"] { #expect(!saved.contains(forbidden)) }
        let key = try #require(json["privateKey"])
        #expect(await world.requests.allSatisfy { !String(decoding: $0, as: UTF8.self).contains(key) })
        let mode = try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? NSNumber
        #expect((mode?.intValue ?? 0o777) & 0o077 == 0)
    }

    @Test func twoTeamsAndMeshesHaveIndependentKeysWithTheSameInstallSigner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeScope(), second = try makeScope("b", mesh: "1"), (world, identity) = try await setup([first, second], root: root)
        let a = try await client(first, world: world, identity: identity, root: root).enroll()
        let b = try await client(second, world: world, identity: identity, root: root).enroll()
        #expect(a.wgPublicKey != b.wgPublicKey && a.device != b.device)
        #expect(await world.auth.registrations == 1)
        #expect(records(root).count == 2)
    }

    @Test(arguments: [false, true])
    func lostRepliesRecoverWithoutDuplicateEnrollmentOrBinding(binding: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try makeScope(), (world, identity) = try await setup([scope], root: root)
        if binding { await world.loseBindingReply() } else { await world.loseEnrollmentReply() }
        let service = try client(scope, world: world, identity: identity, root: root)
        await #expect(throws: (any Error).self) { try await service.enroll() }
        _ = try await service.enroll()
        #expect(await world.enrollments == 1)
        #expect(await world.binds == 1)
        if binding {
            let keys = await world.bindKeys
            #expect(keys.count == 2 && Set(keys).count == 1)
        }
    }

    @Test(arguments: ["tenantId", "meshId", "deviceId", "wgPublicKey", "installPublicKey", "missingTenant"])
    func mismatchedPolicyNeverReachesBackendBinding(field: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try makeScope(), (world, identity) = try await setup([scope], root: root)
        await world.setBadPolicy(field)
        let service = try client(scope, world: world, identity: identity, root: root)
        await #expect(throws: (any Error).self) { try await service.enroll() }
        #expect(await world.binds == 0)
    }

    @Test func aForeignNativeSessionIsNeverForwarded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try makeScope(), (world, identity) = try await setup([scope], root: root)
        let service = try client(scope, world: world, identity: identity, root: root, session: { NativeDeviceTestWorld.session("someone_else") })
        await #expect(throws: NativeDeviceEnrollmentError.signedOut) { try await service.enroll() }
        #expect(await world.enrollments == 0)
        #expect(await world.binds == 0)
    }

    @Test func aSessionFromAnotherStackProjectIsNeverForwarded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try makeScope(), (world, identity) = try await setup([scope], root: root)
        let service = try client(scope, world: world, identity: identity, root: root, session: { NativeDeviceTestWorld.session(project: "another_project") })
        await #expect(throws: NativeDeviceEnrollmentError.signedOut) { try await service.enroll() }
        #expect(await world.enrollments == 0)
    }

    @Test func signOutDuringTheReadPreventsBackendBinding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try makeScope(), (world, identity) = try await setup([scope], root: root)
        await world.onPolicy { await identity.unbind() }
        let service = try client(scope, world: world, identity: identity, root: root)
        await #expect(throws: MacInstallIdentity.Failure.signedOut) { try await service.enroll() }
        #expect(await world.binds == 0)
        try await service.revoke()
        #expect(await world.deletions == 1)
    }

    @Test func revocationDrainsARegistrationAlreadyOnTheWireThenDeletesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try makeScope(), (world, identity) = try await setup([scope], root: root)
        await world.holdEnrollment()
        let service = try client(scope, world: world, identity: identity, root: root)
        let request = Task { try await service.enroll() }
        defer { request.cancel(); Task { await world.release() } }
        await world.waitUntilHeld()
        await service.stop()
        let revoke = Task { try await service.revoke() }
        await world.release()
        await #expect(throws: NativeDeviceEnrollmentError.revoked) { try await request.value }
        try await revoke.value
        #expect(await world.deletions == 1)
        #expect(await world.binds == 0)
        await #expect(throws: NativeDeviceEnrollmentError.revoked) { try await service.enroll() }
    }

    @Test func legacyDevicesWithoutInstallKeysDoNotBlockEnrollment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try makeScope(), (world, identity) = try await setup([scope], root: root)
        await world.includeLegacyDevice()
        _ = try await client(scope, world: world, identity: identity, root: root).enroll()
        #expect(await world.binds == 1)
    }

    @Test func aMismatchedBackendAcknowledgmentIsNotReturnedAsConfirmed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try makeScope(), (world, identity) = try await setup([scope], root: root)
        await world.setBadAck()
        let service = try client(scope, world: world, identity: identity, root: root)
        await #expect(throws: NativeDeviceEnrollmentError.invalidIdentity) { try await service.enroll() }
    }
}
