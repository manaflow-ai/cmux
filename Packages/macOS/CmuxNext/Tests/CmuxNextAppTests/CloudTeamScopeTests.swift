import CmuxInstallAuthCore
import Foundation
import Testing
@testable import CmuxNextCloud

@Suite struct CloudTeamScopeTests {
    private func setup(_ root: URL, session: @escaping InstallAuthClient.SessionToken = { NativeDeviceTestWorld.session() }) async throws
        -> (CloudTeamScopeWorld, MacInstallIdentity, CloudTeamScope) {
        let world = CloudTeamScopeWorld()
        let identity = MacInstallIdentity(store: .files(directory: root), transport: world, deviceName: "Test Mac", clientVersion: "2.4.0")
        try await identity.signedIn(stackUser: "stack_1", session: { "test-session" })
        return (world, identity, CloudTeamScope(identity: identity, transport: world, selection: { await world.selection() }, session: session))
    }

    @Test func theOwnersConfirmedReferenceSelectsTheScopedSigner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (world, identity, scope) = try await setup(root)
        let token = try await scope.token()
        #expect(MacInstallIdentity.team(ofToken: token) == CloudTeamScopeWorld.shared)
        #expect(await world.owner.requestedTeams == [CloudTeamScopeWorld.shared])
        #expect(await world.owner.registrations == 1)
        #expect(MacInstallIdentity.team(ofToken: try await identity.installToken()) == CloudTeamScopeWorld.personal)
    }

    @Test func personalSelectionIsExplicitlyResolvedAndMinted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (world, _, scope) = try await setup(root)
        await world.select(nil)
        #expect(MacInstallIdentity.team(ofToken: try await scope.token()) == CloudTeamScopeWorld.personal)
        #expect(await world.owner.requestedTeams == [CloudTeamScopeWorld.personal])
    }

    @Test(arguments: ["missing", "incomplete", "duplicate", "sso", "wrong-personal", "bad-id", "missing-reference"])
    func uncertainOrRefusedSelectionsNeverFallBackToThePersonalTeam(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (world, _, scope) = try await setup(root)
        await world.setMode(mode)
        let failure: CloudTeamScope.Failure = switch mode {
        case "missing", "missing-reference": .notMember
        case "incomplete": .unavailable
        case "sso": .ssoRequired
        default: .invalidIdentity
        }
        await #expect(throws: failure) { try await scope.token() }
        #expect(await world.owner.requestedTeams.isEmpty)
    }

    @Test func aDeniedScopedGrantDoesNotMintInAnotherTeam() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (world, _, scope) = try await setup(root)
        await world.owner.deny(CloudTeamScopeWorld.shared)
        await #expect(throws: InstallAuthError.refused("auth.forbidden")) { try await scope.token() }
        #expect(await world.owner.requestedTeams == [CloudTeamScopeWorld.shared])
    }

    @Test func aSelectionChangeDuringTheOwnerReadCannotMint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (world, _, scope) = try await setup(root)
        await world.onReply { await world.select("tenant_b") }
        await #expect(throws: CloudTeamScope.Failure.changed) { try await scope.token() }
        #expect(await world.owner.requestedTeams.isEmpty)
    }

    @Test func switchingAwayAndBackDuringMintInvalidatesTheOriginalRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (world, _, scope) = try await setup(root)
        await world.owner.holdNextTeamToken()
        let mint = Task { try await scope.token() }
        defer { mint.cancel(); Task { await world.owner.release() } }
        await world.owner.waitUntilHeld()
        await world.select("tenant_b")
        await world.select("tenant_a")
        await world.owner.release()
        await #expect(throws: CloudTeamScope.Failure.changed) { try await mint.value }
    }

    @Test(arguments: ["account", "project"])
    func aSessionForAnotherIdentityNeverReachesTheTeamListing(field: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (world, _, scope) = try await setup(root, session: {
            NativeDeviceTestWorld.session(field == "account" ? "other" : "stack_1", project: field == "project" ? "other" : NativeDeviceTestWorld.project)
        })
        await #expect(throws: NativeDeviceEnrollmentError.signedOut) { try await scope.token() }
        #expect(await world.listings == 0)
        #expect(await world.owner.requestedTeams.isEmpty)
    }

    @Test func signingOutInvalidatesAnAlreadyResolvedSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, identity, scope) = try await setup(root)
        let snapshot = try await scope.snapshot()
        await identity.unbind()
        await #expect(throws: MacInstallIdentity.Failure.signedOut) { try await snapshot.recheck() }
        await #expect(throws: MacInstallIdentity.Failure.signedOut) { try await snapshot.sessionToken() }
    }

    @Test func approvalStepsKeepTheirOriginalTeamAndRefuseAfterSelectionChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (world, _, scope) = try await setup(root)
        let snapshot = try await scope.snapshot(), body = Data(#"{"op":"feed.answer","params":{}}"#.utf8)
        _ = try await snapshot.call("v1/ops", body)
        #expect(await world.operationTeams == [CloudTeamScopeWorld.shared])
        await world.select("tenant_b")
        await #expect(throws: CloudTeamScope.Failure.changed) { try await snapshot.call("v1/ops", body) }
        #expect(await world.operationTeams == [CloudTeamScopeWorld.shared])
    }

    @Test(arguments: ["https://other.test/v1/ops", "v1/ops?target=other", "v1/auth/token"])
    func snapshotCallsCannotRedirectTheSessionToAnotherRoute(path: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (world, _, scope) = try await setup(root)
        let snapshot = try await scope.snapshot()
        await #expect(throws: CloudTeamScope.Failure.invalidRequest) { try await snapshot.call(path, Data()) }
        #expect(await world.operationTeams.isEmpty)
    }
}
