import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// OWNERSHIP-PRINCIPLES.md: every action.run carries its origin; only a
/// user's run (or one asking `focus: true`) may change this client's view.
/// A run without `origin` is a CLI run.
@MainActor
@Suite struct ActionOriginTests {
    func run(_ params: [String: JSONValue]) async -> (Result<JSONValue, ControlError>, ActionInvocation?) {
        let registry = ActionRegistry.standard()
        var seen: ActionInvocation?
        registry.bind("splitRight", invoke: { seen = $0 })
        let bridge = RegistryControlBridge(registry: registry)
        let router = ControlRouter(identity: testIdentity(), executor: bridge, settings: nil)
        router.updateCatalog(RegistryControlBridge.catalog(from: registry))
        var all = params
        all["action"] = .string("splitRight")
        let result = await router.handle(ControlRequest(id: "1", method: "action.run", params: all))
        return (result, seen)
    }

    @Test func aRunWithoutOriginIsTheCLIAndChangesNoView() async throws {
        let (result, invocation) = await run([:])
        _ = try result.get()
        #expect(invocation?.origin == .cli)
        #expect(invocation?.allowsViewChange == false)
    }

    @Test func focusTrueOrAUserOriginAllowsAViewChange() async throws {
        let (_, asked) = await run(["focus": true])
        #expect(asked?.allowsViewChange == true)
        let (_, user) = await run(["origin": "user"])
        #expect(user?.origin == .user)
        #expect(user?.allowsViewChange == true)
        let (_, agent) = await run(["origin": "mcp"])
        #expect(agent?.allowsViewChange == false)
    }

    @Test func anUnknownOriginIsRefused() async {
        let (result, invocation) = await run(["origin": "robot"])
        guard case .failure(let error) = result else {
            Issue.record("expected invalid params")
            return
        }
        #expect(error.code == "invalid_params")
        #expect(invocation == nil)
    }

    /// Import Passwords from CSV is a person's: the socket refuses it even
    /// when the caller claims to be the user, and the handler never runs.
    @Test func thePasswordCSVImportIsRefusedOverTheSocket() async {
        let registry = ActionRegistry.standard()
        var ran = false
        registry.bind("password.importCSV", invoke: { _ in ran = true })
        let bridge = RegistryControlBridge(registry: registry)
        let router = ControlRouter(identity: testIdentity(), executor: bridge, settings: nil)
        router.updateCatalog(RegistryControlBridge.catalog(from: registry))
        for origin: JSONValue in ["user", "cli", "mcp", .null] {
            let result = await router.handle(ControlRequest(id: "1", method: "action.run", params: [
                "action": "password.importCSV", "origin": origin,
            ]))
            guard case .failure(let error) = result else {
                Issue.record("expected a refusal for origin \(origin)")
                continue
            }
            #expect(error.code == "unavailable")
            #expect(error.data?["reason"] == .string(ControlStrings.text("control.error.personOnly", "Only a person in cmux can run this action")))
        }
        #expect(!ran)
        #expect(registry.descriptor(for: "password.importCSV")?.isPersonOnly == true)
    }

    @Test func inAppRunsAreTheUsers() {
        #expect(ActionInvocation().origin == .user)
        #expect(ActionInvocation().allowsViewChange)
    }
}
