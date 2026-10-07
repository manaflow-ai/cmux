import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// `action.run` reports typed "unavailable: <reason>" errors end to end
/// through the real registry bridge, and `action.list` carries the reason.
@MainActor
@Suite struct UnavailableReasonTests {
    func router(for registry: ActionRegistry) -> ControlRouter {
        let bridge = RegistryControlBridge(registry: registry)
        let router = ControlRouter(identity: testIdentity(), executor: bridge, settings: nil, configuration: .loadTolerant)
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

    @Test func handlerRefusalIsReported() async {
        let registry = ActionRegistry.standard()
        registry.bind("jumpToUnread") { registry.refuse("nothing unread") }
        guard case .failure(let error) = await run(router(for: registry), "jumpToUnread") else {
            Issue.record("expected unavailable")
            return
        }
        #expect(error.code == "unavailable")
        #expect(error.message == "jumpToUnread unavailable: nothing unread")
    }
}
