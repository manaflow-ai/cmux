import CmuxNextApps
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
import Testing
@testable import CmuxNextApp

/// Exercise the provider-to-action boundary through the real control router.
@MainActor struct ActionAppMutationKeyTests {
    @MainActor final class Executor: ControlActionExecutor {
        var requests: [ControlActionRequest] = []
        var keys: [String?] = []

        func performAction(_ request: ControlActionRequest) -> ControlActionOutcome {
            requests.append(request)
            keys.append(DaemonCommandScope.current?.idempotencyKey)
            return .ran
        }
    }

    private func make() -> (ActionAppOps, Executor) {
        let executor = Executor()
        let router = ControlRouter(identity: ControlIdentity(version: "test", build: "1", bundleID: nil, tag: nil, processID: 0),
                                   executor: executor, configuration: .init(requestDeadline: .seconds(30)))
        let action = ControlActionInfo(id: "test.ownerJob", title: "Test Job", category: "test", categoryTitle: "Test",
            cliName: "test job", symbol: "terminal", keywords: [], shortcut: nil, shortcutConfig: nil,
            arguments: [.init(name: "cli", title: "CLI", kind: .string, isRequired: true)],
            targets: [], requiresMask: 0, requires: [], isBound: true, isDebugOnly: false, mainMenu: nil)
        router.snapshots.publish { $0.catalog = ControlCatalog(actions: [action], debugActionsAvailable: false) }
        return (ActionAppOps(control: { method, params, app throws(AppHostCapabilityError) in
            try await router.appControl(method, params, callerApp: app)
        }), executor)
    }

    private func request(key: String?, cli: String = "codex", origin: String = "script",
                         claimedKey: String = "params-cannot-pick-the-key") -> AppHostCapabilityRequest {
        AppHostCapabilityRequest(app: "cmux/agents", op: "action.run", params: .object([
            "id": .string("test.ownerJob"), "args": .object(["cli": .string(cli)]),
            "idempotency_key": .string(claimedKey), "origin": .string("user"),
        ]), origin: origin, idempotencyKey: key, actor: .object(["kind": .string("app"), "id": .string("cmux/agents")]))
    }

    @Test(arguments: ["user", "script"])
    func aRetriedAdmittedActionReplaysItsOriginalKeyWithoutChangingOrigin(origin: String) async throws {
        let (handler, executor) = make()
        let key = "app:cmux/agents:original key"
        _ = try await handler.handle(request(key: key, origin: origin, claimedKey: "first-forged-key"))
        let replay = try await handler.handle(request(key: key, origin: origin, claimedKey: "second-forged-key"))
        #expect(executor.requests.count == 1)
        #expect(executor.requests.first?.origin == origin)
        #expect(executor.keys == [key])
        #expect(replay["replayed"]?.boolValue == true)
    }

    @Test func changedIntentWithTheOriginalKeyConflictsBeforeAnotherActionRuns() async throws {
        let (handler, executor) = make()
        _ = try await handler.handle(request(key: "same-intent"))
        do {
            _ = try await handler.handle(request(key: "same-intent", cli: "claude"))
            Issue.record("changed intent ran under an existing mutation key")
        } catch let error as AppHostCapabilityError {
            #expect(error.code == "idempotency_conflict")
        }
        #expect(executor.requests.count == 1)
        #expect(executor.keys == ["same-intent"])
    }

    @Test func differentAdmittedKeysRemainIndependent() async throws {
        let (handler, executor) = make()
        _ = try await handler.handle(request(key: "first-intent"))
        _ = try await handler.handle(request(key: "second-intent"))
        #expect(executor.requests.count == 2)
        #expect(executor.keys == ["first-intent", "second-intent"])
    }

    @Test func aLegacyCallWithoutAKeyDoesNotAcquireOneFromParams() async throws {
        let (handler, executor) = make()
        _ = try await handler.handle(request(key: nil))
        _ = try await handler.handle(request(key: nil))
        #expect(executor.requests.count == 2)
        #expect(executor.keys == [nil, nil])
        #expect(executor.requests.allSatisfy { $0.origin == "script" })
    }
}
