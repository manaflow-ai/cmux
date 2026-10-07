import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// A socket caller is never the in-app user (identity.md section 3,
/// OWNERSHIP-PRINCIPLES): `action.run` from the control socket refuses
/// `origin: "user"`, the same rule `palette.run` applies. In-process callers
/// (the app's own pages) keep it.
@MainActor
@Suite struct ActionOriginSocketTests {
    func run(_ origin: JSONValue, connection: ControlConnectionID) async -> (Result<JSONValue, ControlError>, ActionInvocation?) {
        let registry = ActionRegistry.standard()
        var seen: ActionInvocation?
        registry.bind("splitRight", invoke: { seen = $0 })
        let router = ControlRouter(identity: testIdentity(), executor: RegistryControlBridge(registry: registry), settings: nil, configuration: .loadTolerant)
        router.updateCatalog(RegistryControlBridge.catalog(from: registry))
        let result = await router.handle(
            ControlRequest(id: "1", method: "action.run", params: ["action": "splitRight", "origin": origin]),
            connection: connection
        )
        return (result, seen)
    }

    @Test func aSocketCallerCannotClaimTheUserOrigin() async {
        let (result, invocation) = await run("user", connection: ControlConnectionID(rawValue: 7))
        guard case .failure(let error) = result else {
            Issue.record("a socket caller ran as the user")
            return
        }
        #expect(error.code == "invalid_params")
        #expect(error.message == "origin must be cli, mcp, script or remote")
        #expect(invocation == nil)
    }

    /// `tab.focus` forwards the caller's params to `action.run` on the same
    /// connection, so it gets the same refusal.
    @Test func tabFocusFromTheSocketCannotClaimTheUserOrigin() async {
        let registry = ActionRegistry.standard()
        var ran = false
        registry.bind("tab.focus", invoke: { _ in ran = true })
        let router = ControlRouter(identity: testIdentity(), executor: RegistryControlBridge(registry: registry), settings: nil, configuration: .loadTolerant)
        router.updateCatalog(RegistryControlBridge.catalog(from: registry))
        let result = await router.handle(
            ControlRequest(id: "1", method: "tab.focus", params: ["tab": "tab_1", "origin": "user"]),
            connection: ControlConnectionID(rawValue: 7)
        )
        guard case .failure(let error) = result else {
            Issue.record("tab.focus ran as the user from the socket")
            return
        }
        #expect(error.code == "invalid_params")
        #expect(!ran)
    }

    @Test(arguments: ["cli", "mcp", "script", "remote"])
    func aSocketCallerKeepsItsHeadlessOrigins(origin: String) async throws {
        let (result, invocation) = await run(.string(origin), connection: ControlConnectionID(rawValue: 7))
        _ = try result.get()
        #expect(invocation?.origin.rawValue == origin)
        #expect(invocation?.allowsViewChange == false)
    }

    @Test func anInProcessCallerKeepsTheUserOrigin() async throws {
        let (result, invocation) = await run("user", connection: .inProcess)
        _ = try result.get()
        #expect(invocation?.origin == .user)
    }
}
