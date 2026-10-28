import CmuxNextActions
import CmuxNextApps
import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// Attribution after admission: the production provider, router, bridge and registry.
@MainActor struct ActionCallerAttributionTests {
    @MainActor final class Recorder {
        var invocations: [ActionInvocation] = []
    }

    private func make() -> (handler: ActionAppOps, router: ControlRouter, registry: ActionRegistry,
                            bridge: RegistryControlBridge, recorder: Recorder) {
        let registry = ActionRegistry(catalog: [.init(id: "test.caller", title: "Test Caller", category: .other)])
        let recorder = Recorder()
        registry.bind("test.caller", invoke: { recorder.invocations.append($0) })
        let bridge = RegistryControlBridge(registry: registry)
        let router = ControlRouter(identity: ControlIdentity(version: "test", build: "1", bundleID: nil, tag: nil, processID: 0),
                                   executor: bridge, configuration: .init(requestDeadline: .seconds(30)))
        bridge.attach(to: router)
        let handler = ActionAppOps(control: { method, params, app throws(AppHostCapabilityError) in
            try await router.appControl(method, params, callerApp: app)
        })
        return (handler, router, registry, bridge, recorder)
    }

    private func request(app: String, origin: String = "user", key: String = "original-key") -> AppHostCapabilityRequest {
        AppHostCapabilityRequest(app: app, op: "action.run", params: .object([
            "id": .string("test.caller"), "caller_app": .string("cmux/forged-param"),
            "app": .string("cmux/another-forged-param"), "origin": .string("user"),
        ]), origin: origin, idempotencyKey: key, actor: .object(["app": .string("cmux/opaque-actor")]))
    }

    @Test(arguments: ["user", "script"])
    func anAppsGestureKeepsItsAppPrincipalThroughTheActualRegistry(origin: String) async throws {
        let h = make()
        defer { h.bridge.detach() }
        _ = try await h.handler.handle(request(app: "cmux/agents", origin: origin))
        let invocation = try #require(h.recorder.invocations.first)
        #expect(h.recorder.invocations.count == 1)
        #expect(invocation.origin.rawValue == origin)
        #expect(invocation.callerApp == "cmux/agents")
    }

    @Test func anotherAppCannotReplayTheFirstAppsKeyAsItsOwnAction() async throws {
        let h = make()
        defer { h.bridge.detach() }
        _ = try await h.handler.handle(request(app: "cmux/first"))
        do {
            _ = try await h.handler.handle(request(app: "cmux/second"))
            Issue.record("a different app replayed another principal's action")
        } catch let error as AppHostCapabilityError {
            #expect(error.code == "idempotency_conflict")
        }
        let replay = try await h.handler.handle(request(app: "cmux/first"))
        #expect(replay["replayed"]?.boolValue == true)
        #expect(h.recorder.invocations.count == 1)
        #expect(h.recorder.invocations.first?.callerApp == "cmux/first")
    }

    @Test(arguments: ["script", "user"])
    func wireClaimsCannotCreateProviderAttributionOrUserOrigin(origin: String) async throws {
        let h = make()
        defer { h.bridge.detach() }
        let line = #"{"id":"wire","method":"action.run","caller_app":"cmux/forged-envelope","params":{"action":"test.caller","origin":"ORIGIN","caller_app":"cmux/forged-param"}}"#
            .replacingOccurrences(of: "ORIGIN", with: origin)
        let reply = await h.router.response(forLine: line, connection: ControlConnectionID(rawValue: 42))
        let response = try JSONValue.parse(Data(reply.utf8))
        #expect(response["ok"]?.boolValue == (origin == "script"))
        if origin == "script" {
            #expect(h.recorder.invocations.count == 1)
            #expect(h.recorder.invocations.first?.callerApp == nil)
            #expect(h.recorder.invocations.first?.origin == .script)
        } else {
            #expect(h.recorder.invocations.isEmpty)
        }
    }

    @Test func aDirectNativeGestureHasNoAppAttribution() throws {
        let h = make()
        defer { h.bridge.detach() }
        #expect(h.registry.perform("test.caller"))
        let invocation = try #require(h.recorder.invocations.first)
        #expect(invocation.origin == .user && invocation.callerApp == nil)
    }
}
