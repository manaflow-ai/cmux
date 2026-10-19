import CmuxInstallAuthCore
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextCloud

@MainActor @Suite struct CloudMachineMutationTests {
    private actor Calls {
        struct Call: Sendable {
            let scope: String
            let op: String
            let args: JSONValue
            let key: String?
            let origin: AppsRunRequest.Origin
        }
        var app: [Call] = []
        var legacy = 0
        func record(_ call: Call) { app.append(call) }
        func recordLegacy() { legacy += 1 }
    }

    private func resolver(_ root: URL, world: CloudTeamScopeWorld) async throws -> CloudTeamScope {
        let identity = MacInstallIdentity(store: .files(directory: root), transport: world,
            deviceName: "Test Mac", clientVersion: "2.4.0")
        try await identity.signedIn(stackUser: "stack_1", session: { "test-session" })
        return CloudTeamScope(identity: identity, transport: world,
            selection: { await world.selection() }, session: { NativeDeviceTestWorld.session() })
    }

    private func client(_ scope: CloudTeamScope, calls: Calls, appServer: Bool = true,
                        reply: @escaping @Sendable () async throws -> Void = {}) -> CloudMachineMutations {
        CloudMachineMutations(appServer: appServer, snapshot: { try await scope.snapshot() },
            ops: { snapshot in { op, args, key, origin in
                await calls.record(.init(scope: snapshot.id, op: op, args: args, key: key, origin: origin))
                try await reply()
                return .object([:])
            } }, check: { _ in }, legacy: { _, _ in await calls.recordLegacy() })
    }

    @Test(arguments: [CloudMachineMutations.Mutation.delete, .pause, .resume, .rename("New name")])
    func appServerActionsReachTheCanonicalOwner(mutation: CloudMachineMutations.Mutation) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let world = CloudTeamScopeWorld(), calls = Calls()
        let scope = try await resolver(root, world: world)
        let expected = try await scope.snapshot()
        var committed = false
        try await client(scope, calls: calls).run(mutation, machine: "vm-alpha01", origin: .user) { committed = true }
        #expect(await calls.legacy == 0)
        let recorded = await calls.app
        #expect(recorded.count == 1)
        let call = try #require(recorded.first)
        let op: String = switch mutation {
        case .delete: "cloud.machine.delete"
        case .pause: "cloud.machine.pause"
        case .resume: "cloud.machine.start"
        case .rename: "cloud.machine.rename"
        }
        #expect(call.op == op && call.scope == expected.id)
        #expect(call.args["machine"]?.stringValue == "vm-alpha01")
        if case .rename(let name) = mutation { #expect(call.args["name"]?.stringValue == name) }
        #expect(call.key?.isEmpty == false && call.origin == .user)
        #expect(committed)
    }

    @Test func theLegacyConfigurationRetainsItsExistingMutationPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let world = CloudTeamScopeWorld(), calls = Calls()
        let scope = try await resolver(root, world: world)
        try await client(scope, calls: calls, appServer: false).run(.pause, machine: "vm-alpha01", origin: .script) { }
        #expect(await calls.legacy == 1)
        #expect(await calls.app.isEmpty)
        #expect(await world.listings == 0)
    }

    @Test(arguments: [CloudMachineMutations.Mutation.delete, .pause, .resume, .rename("New name")])
    func aTeamSwitchDuringTheMutationCannotCommitItsOldResult(mutation: CloudMachineMutations.Mutation) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let world = CloudTeamScopeWorld(), calls = Calls()
        let scope = try await resolver(root, world: world)
        var committed = false
        await #expect(throws: CloudTeamScope.Failure.changed) {
            try await client(scope, calls: calls, reply: { await world.select("tenant_b") })
                .run(mutation, machine: "vm-alpha01", origin: .script) { committed = true }
        }
        #expect(!committed)
        #expect(await calls.legacy == 0)
        #expect(await calls.app.first?.origin == .script)
    }

    @Test func aScopedRefusalIsNeverRetriedThroughTheLegacyAPI() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let world = CloudTeamScopeWorld(), calls = Calls()
        let scope = try await resolver(root, world: world)
        await world.setMode("sso")
        var committed = false
        await #expect(throws: CloudTeamScope.Failure.ssoRequired) {
            try await client(scope, calls: calls).run(.pause, machine: "vm-alpha01", origin: .script) { committed = true }
        }
        #expect(!committed)
        #expect(await calls.legacy == 0)
        #expect(await calls.app.isEmpty)
    }

    @Test func clearingACustomNameUsesTheCanonicalDefaultTitle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let world = CloudTeamScopeWorld(), calls = Calls()
        let scope = try await resolver(root, world: world)
        try await client(scope, calls: calls).run(.rename(""), machine: "vm-alpha01", origin: .user) { }
        #expect(await calls.app.first?.args["name"]?.stringValue == "vm-alpha01")
        #expect(await calls.legacy == 0)
    }

    @Test func aDestructiveScriptRefusalDoesNotBecomeAUserGestureOrLegacyCall() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let world = CloudTeamScopeWorld(), calls = Calls()
        let scope = try await resolver(root, world: world)
        let refusal = CloudAppOpFailure(code: "cmux.cloud.origin_refused", message: "user required")
        var committed = false
        await #expect(throws: refusal) {
            try await client(scope, calls: calls, reply: { throw refusal })
                .run(.delete, machine: "vm-alpha01", origin: .script) { committed = true }
        }
        #expect(!committed)
        #expect(await calls.app.count == 1)
        #expect(await calls.app.first?.origin == .script)
        #expect(await calls.legacy == 0)
    }
}
