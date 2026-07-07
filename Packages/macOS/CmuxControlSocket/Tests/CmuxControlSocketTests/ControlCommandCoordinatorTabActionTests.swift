import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator tab-action domain")
struct ControlCommandCoordinatorTabActionTests {
    @Test func toggleFullWidthTabPayloadIncludesResultingMode() throws {
        let windowID = UUID()
        let workspaceID = UUID()
        let paneID = UUID()
        let surfaceID = UUID()
        let context = FakeTabActionControlCommandContext()
        context.resolution = .completed(ControlTabActionResolution.Outcome(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            windowID: windowID,
            paneID: paneID,
            extras: .fullWidthTabMode(true)
        ))
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "tab.action",
            params: [
                "action": .string("toggle-full-width-tab"),
                "surface_id": .string(surfaceID.uuidString),
            ]
        ))

        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected successful tab.action payload")
            return
        }

        #expect(context.actionKey == "toggle_full_width_tab")
        #expect(context.surfaceID == surfaceID)
        #expect(payload["action"] == .string("toggle_full_width_tab"))
        #expect(payload["window_id"] == .string(windowID.uuidString))
        #expect(payload["workspace_id"] == .string(workspaceID.uuidString))
        #expect(payload["pane_id"] == .string(paneID.uuidString))
        #expect(payload["surface_id"] == .string(surfaceID.uuidString))
        #expect(payload["tab_id"] == .string(surfaceID.uuidString))
        #expect(payload["full_width_tab_mode"] == .bool(true))
    }

    @Test func unknownTabActionAdvertisesFullWidthToggle() throws {
        let context = FakeTabActionControlCommandContext()
        context.resolution = .unknownAction
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "tab.action",
            params: ["action": .string("unknown")]
        ))

        guard case .err(let code, let message, let data) = result else {
            Issue.record("expected unknown tab.action error")
            return
        }

        #expect(code == "invalid_params")
        #expect(message == "Unknown tab action")
        guard case .object(let payload)? = data,
              case .array(let supportedActions)? = payload["supported_actions"] else {
            Issue.record("expected supported_actions payload")
            return
        }
        #expect(supportedActions.contains(.string("toggle_full_width_tab")))
    }
}
