import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// `action.run` reports typed "unavailable: <reason>" and "failed: <reason>"
/// errors end to end through the real registry bridge.
@MainActor
@Suite struct UnavailableReasonTests {
    func router(for registry: ActionRegistry) -> ControlRouter {
        let bridge = RegistryControlBridge(registry: registry)
        let router = ControlRouter(identity: testIdentity(), executor: bridge, settings: nil)
        router.updateCatalog(RegistryControlBridge.catalog(from: registry))
        return router
    }

    func run(_ router: ControlRouter, _ action: String) async -> Result<JSONValue, ControlError> {
        await router.handle(ControlRequest(id: "1", method: "action.run", params: ["action": .string(action)]))
    }

    @Test func unavailableReasonWinsOverTheContextCheck() async {
        let registry = ActionRegistry.standard()
        registry.bindUnavailable("diffViewerNextHunk", reason: "no diff viewer")
        registry.context = []
        guard case .failure(let error) = await run(router(for: registry), "browser diff-next-hunk") else {
            Issue.record("expected unavailable")
            return
        }
        #expect(error.code == "unavailable")
        #expect(error.message == "diffViewerNextHunk unavailable: no diff viewer")
        #expect(error.data?["reason"] == "no diff viewer")
    }

    @Test func listReportsTheReason() async throws {
        let registry = ActionRegistry.standard()
        registry.bindUnavailable("palette.cloud.fork", reason: "cloud later")
        let list = try await router(for: registry).handle(ControlRequest(id: "1", method: "action.list", params: [:])).get()
        let entry = try #require(list["actions"]?.arrayValue?.first { $0["id"] == "palette.cloud.fork" })
        #expect(entry["unavailable_reason"] == "cloud later")
        #expect(entry["bound"] == true)
    }

    @Test func handlerFailureIsAFailedError() async {
        let registry = ActionRegistry.standard()
        registry.bind("jumpToUnread") { registry.fail("nothing unread") }
        guard case .failure(let error) = await run(router(for: registry), "jumpToUnread") else {
            Issue.record("expected failed")
            return
        }
        #expect(error.code == "failed")
        #expect(error.message == "jumpToUnread failed: nothing unread")
    }

    @Test func executorOutcomesWithReasonsMapToErrors() async {
        let cases: [(ControlActionOutcome, String)] = [(.unsupported(reason: "r"), "unavailable"), (.failed(reason: "r"), "failed")]
        for (outcome, code) in cases {
            let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(outcome: outcome), settings: nil)
            router.updateCatalog(sampleCatalog())
            let result = await router.handle(ControlRequest(id: "1", method: "action.run", params: ["action": "workspace-group collapse", "target": "g"]))
            guard case .failure(let error) = result else {
                Issue.record("expected \(code)")
                continue
            }
            #expect(error.code == code)
            #expect(error.data?["reason"] == "r")
        }
    }
}
