import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator system tab actions")
struct ControlCommandCoordinatorSystemTabActionTests {
    private final class FakeSystemTabActionContext: ControlCommandContext {
        var resolution: ControlTabActionResolution = .tabManagerUnavailable
        var receivedTitle: String?
        var receivedTitleSource: String?

        func controlTabAction(
            routing: ControlRoutingSelectors,
            actionKey: String?,
            title: String?,
            titleSource: String?,
            rawURL: String?,
            surfaceID: UUID?,
            requestedFocus: Bool,
            moveParams: [String: JSONValue]
        ) -> ControlTabActionResolution {
            receivedTitle = title
            receivedTitleSource = titleSource
            return resolution
        }
    }

    private func request(_ params: [String: JSONValue]) -> ControlRequest {
        ControlRequest(id: .int(1), method: "tab.action", params: params)
    }

    @Test func tabActionForwardsAutoTitleSource() throws {
        let context = FakeSystemTabActionContext()
        let workspaceID = UUID()
        let surfaceID = UUID()
        context.resolution = .completed(ControlTabActionResolution.Outcome(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            windowID: nil,
            paneID: nil,
            extras: .title("Next Title")
        ))
        let coordinator = ControlCommandCoordinator(context: context)

        guard case .ok(.object(let payload)) = coordinator.handle(request([
            "action": .string("rename"),
            "surface_id": .string(surfaceID.uuidString),
            "title": .string(" Next Title "),
            "title_source": .string(" auto "),
        ])) else {
            Issue.record("unexpected tab.action result")
            return
        }

        #expect(context.receivedTitle == "Next Title")
        #expect(context.receivedTitleSource == "auto")
        #expect(payload["title"] == .string("Next Title"))
    }

    @Test func tabActionMapsUserOwnedTitleRejection() {
        let context = FakeSystemTabActionContext()
        context.resolution = .titleUserOwned
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(request([
            "action": .string("rename"),
            "title": .string("Next Title"),
            "title_source": .string("auto"),
        ]))

        #expect(result == .err(code: "title_user_owned", message: "Tab title is user-owned", data: nil))
    }
}
