import CmuxInstallAuthCore
import CryptoKit
import Foundation
import Testing
@testable import CmuxNextCloud

@Suite struct CloudAuthorityLeaseSourceTests {
    private func setup(_ root: URL) async throws -> (CloudTeamScopeWorld, MacInstallIdentity, CloudTeamScope) {
        let world = CloudTeamScopeWorld(wireTokens: true)
        let identity = MacInstallIdentity(store: .files(directory: root), transport: world, deviceName: "Test Mac", clientVersion: "2.4.0")
        try await identity.signedIn(stackUser: "stack_1", session: { "test-session" })
        let scopes = CloudTeamScope(identity: identity, transport: world,
            selection: { await world.selection() }, session: { NativeDeviceTestWorld.session() })
        return (world, identity, scopes)
    }

    @Test func bothOwnerLeasesRetainTheOriginalInstallAndReuseScopedClients() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (world, identity, scopes) = try await setup(root)
        let context = try await identity.accountContext(), snapshot = try await scopes.snapshot()
        async let a = snapshot.wireLeases(), b = snapshot.wireLeases()
        let first = try await a, second = try await b
        #expect(first.count == 2 && second.count == 2)
        #expect(first.map(\.owner) == [.user, .team])
        #expect(first.map(\.team) == [CloudTeamScopeWorld.personal, CloudTeamScopeWorld.shared])
        #expect(first.allSatisfy { $0.user == context.user && $0.install == context.install && $0.expiresAt > Date() })
        #expect(first.map(\.token) == second.map(\.token))
        #expect(await world.owner.registrations == 1)
        #expect(await world.listings == 1)
        #expect(await world.owner.requestedTeams == [CloudTeamScopeWorld.shared, CloudTeamScopeWorld.personal])
    }

    @Test func personalSelectionStillObservesBothOwnersWithOneScopedCredentialClient() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (world, _, scopes) = try await setup(root)
        await world.select(nil)
        let snapshot = try await scopes.snapshot(), leases = try await snapshot.wireLeases()
        #expect(leases.map(\.owner) == [.user, .team])
        #expect(leases.map(\.team) == [CloudTeamScopeWorld.personal, CloudTeamScopeWorld.personal])
        #expect(leases[0].token == leases[1].token)
        #expect(await world.owner.requestedTeams == [CloudTeamScopeWorld.personal])
    }

    @Test(arguments: ["authority", "selection", "unbound", "revoked"])
    func anOldSnapshotCannotRenewAfterItsOriginalAuthorityChanges(change: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (world, identity, scopes) = try await setup(root)
        let snapshot = try await scopes.snapshot()
        switch change {
        case "authority": await world.changeAuthority(String(repeating: "b", count: 64))
        case "selection": await world.select(nil)
        case "unbound": await identity.unbind()
        default: await world.setAuthorityMode("revoked")
        }
        await #expect(throws: (any Error).self) { try await snapshot.wireLeases() }
        #expect(await world.owner.registrations == 1)
        #expect(await world.owner.requestedTeams == [CloudTeamScopeWorld.shared])
    }

    @Test func aPersonalTeamRefusalCannotRotateOrReregisterTheOriginalSigner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (world, identity, scopes) = try await setup(root)
        let context = try await identity.accountContext(), snapshot = try await scopes.snapshot()
        let point = try #require(await world.owner.publicKey(context.install))
        await world.owner.deny(CloudTeamScopeWorld.personal)
        await #expect(throws: (any Error).self) { try await snapshot.wireLeases() }
        #expect(await world.owner.registrations == 1)
        let raw = try await identity.nativeSign("still original", context: context)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: try #require(Data(base64Encoded: raw)))
        #expect(try P256.Signing.PublicKey(x963Representation: point).isValidSignature(signature, for: Data("still original".utf8)))
    }

    @Test func backgroundAuthorityRefreshCannotEnterPersonalRegistrationRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (world, identity, scopes) = try await setup(root)
        let first = try await scopes.snapshot()
        let original = try await first.wireLeases()
        await identity.invalidate()
        await world.owner.denyPersonalRecovery()
        await world.changeAuthority(String(repeating: "b", count: 64))
        let next = try await first.refreshAuthority(), leases = try await next.wireLeases()
        #expect(next.id != first.id && next.selection == first.selection)
        #expect(leases.map(\.install) == original.map(\.install))
        #expect(await world.owner.registrations == 1)
    }

    @Test func backgroundRefreshCannotAdoptANewerPickerSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (world, _, scopes) = try await setup(root)
        let first = try await scopes.snapshot()
        await world.select(nil)
        await #expect(throws: CloudTeamScope.Failure.changed) { try await first.refreshAuthority() }
        #expect(await world.listings == 1)
        #expect(await world.owner.registrations == 1)
    }
}
