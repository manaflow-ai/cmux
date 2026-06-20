import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator helper domain")
struct ControlCommandCoordinatorHelperTests {
    private func makeCoordinator() -> (ControlCommandCoordinator, FakeHelperControlCommandContext) {
        let context = FakeHelperControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        return (coordinator, context)
    }

    private func request(_ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: "helper.visible", params: params)
    }

    @Test func visibleHelperTargetsFocusedWorkspaceWhenCallerDiffers() async throws {
        let (coordinator, context) = makeCoordinator()
        let result = await coordinator.handleHelperAsync(request([
            "caller": .object(["workspace_id": .string(context.callerWorkspaceID.uuidString)]),
        ]))

        guard case .ok(.object(let payload)) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }

        #expect(payload["workspace_id"] == .string(context.focusedWorkspaceID.uuidString))
        #expect(payload["pane_id"] == .string(context.createdPaneID.uuidString))
        #expect(payload["surface_id"] == .string(context.createdSurfaceID.uuidString))
        #expect(payload["target_workspace_source"] == .string("focused"))
        #expect(payload["caller_focused_diverged"] == .bool(true))
        #expect(payload["placement_strategy"] == .string("created_right_pane"))
        #expect(payload["reused_pane"] == .bool(false))
        #expect(payload["created_pane"] == .bool(true))
        #expect(payload["created_surface"] == .bool(true))
        #expect(payload["sent_command"] == .bool(false))
        #expect(payload["surface_visible"] == .bool(true))
        #expect(payload["surface_health_in_window"] == .bool(true))
        #expect(payload["surface_health_attempts"] == .int(1))
        #expect(payload["surface_window_event_observed"] == .bool(true))
        #expect(context.paneCreateCalls.count == 1)
        #expect(context.surfaceCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.isEmpty)
        #expect(context.surfaceHealthRoutings.count == 2)
        #expect(context.surfaceWindowWaits.count == 1)
        #expect(context.surfaceWindowWaits.first?.surfaceID == context.createdSurfaceID)
        #expect(context.paneCreateCalls.first?.routing.workspaceID == context.focusedWorkspaceID)
        #expect(context.paneCreateCalls.first?.inputs.directionRaw == "right")
        #expect(context.paneCreateCalls.first?.inputs.requestedFocus == false)
    }

    @Test func visibleHelperCreatesVisiblePaneBeforeSendingCommand() async throws {
        let (coordinator, context) = makeCoordinator()
        let result = await coordinator.handleHelperAsync(request([
            "initial_command": .string("echo created"),
        ]))

        guard case .ok(.object(let payload)) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }

        #expect(payload["workspace_id"] == .string(context.focusedWorkspaceID.uuidString))
        #expect(payload["pane_id"] == .string(context.createdPaneID.uuidString))
        #expect(payload["surface_id"] == .string(context.createdSurfaceID.uuidString))
        #expect(payload["created_pane"] == .bool(true))
        #expect(payload["created_surface"] == .bool(true))
        #expect(payload["surface_visible"] == .bool(true))
        #expect(payload["sent_command"] == .bool(true))
        #expect(payload["command_queued"] == .bool(false))
        #expect(context.paneCreateCalls.count == 1)
        #expect(context.paneCreateCalls.first?.inputs.initialCommand == nil)
        #expect(context.surfaceCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.count == 1)
        #expect(context.surfaceSendTextCalls.first?.surfaceID == context.createdSurfaceID)
        #expect(context.surfaceSendTextCalls.first?.text == "echo created\n")
        #expect(context.surfaceWindowWaits.count == 1)
    }

    @Test func visibleHelperWaitsForNewlyCreatedSurfaceWindowEvent() async throws {
        let (coordinator, context) = makeCoordinator()
        context.createdSurfaceVisible = false
        context.createdSurfaceVisibleAfterWindowEvent = true

        let result = await coordinator.handleHelperAsync(request([
            "initial_command": .string("echo delayed"),
        ]))

        guard case .ok(.object(let payload)) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }

        #expect(payload["workspace_id"] == .string(context.focusedWorkspaceID.uuidString))
        #expect(payload["surface_id"] == .string(context.createdSurfaceID.uuidString))
        #expect(payload["surface_visible"] == .bool(true))
        #expect(payload["surface_health_in_window"] == .bool(true))
        #expect(payload["surface_health_attempts"] == .int(1))
        #expect(payload["surface_window_event_observed"] == .bool(true))
        #expect(payload["sent_command"] == .bool(true))
        #expect(context.paneCreateCalls.count == 1)
        #expect(context.surfaceSendTextCalls.count == 1)
        #expect(context.surfaceHealthRoutings.count == 2)
        #expect(context.surfaceWindowWaits.count == 1)
        #expect(context.surfaceWindowWaits.first?.surfaceID == context.createdSurfaceID)
    }

    @Test func visibleHelperReusesExistingRightPaneWithoutDuplicatingPanes() async throws {
        let (coordinator, context) = makeCoordinator()
        context.includeExistingHelperPane = true

        let result = await coordinator.handleHelperAsync(request())

        guard case .ok(.object(let payload)) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }

        #expect(payload["workspace_id"] == .string(context.focusedWorkspaceID.uuidString))
        #expect(payload["pane_id"] == .string(context.helperPaneID.uuidString))
        #expect(payload["surface_id"] == .string(context.helperSurfaceID.uuidString))
        #expect(payload["placement_strategy"] == .string("reused_right_pane"))
        #expect(payload["reused_pane"] == .bool(true))
        #expect(payload["created_pane"] == .bool(false))
        #expect(payload["created_surface"] == .bool(false))
        #expect(payload["sent_command"] == .bool(false))
        #expect(payload["surface_visible"] == .bool(true))
        #expect(payload["surface_health_in_window"] == .bool(true))
        #expect(payload["surface_window_event_observed"] == .null)
        #expect(context.paneCreateCalls.isEmpty)
        #expect(context.surfaceCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.isEmpty)
        #expect(context.surfaceHealthRoutings.count == 2)
    }

    @Test func visibleHelperSendsCommandToExistingVisibleTerminalWithoutDuplicatingPanes() async throws {
        let (coordinator, context) = makeCoordinator()
        context.includeExistingHelperPane = true

        let result = await coordinator.handleHelperAsync(request([
            "initial_command": .string("echo helper"),
        ]))

        guard case .ok(.object(let payload)) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }

        #expect(payload["workspace_id"] == .string(context.focusedWorkspaceID.uuidString))
        #expect(payload["pane_id"] == .string(context.helperPaneID.uuidString))
        #expect(payload["surface_id"] == .string(context.helperSurfaceID.uuidString))
        #expect(payload["placement_strategy"] == .string("reused_right_pane"))
        #expect(payload["reused_pane"] == .bool(true))
        #expect(payload["created_pane"] == .bool(false))
        #expect(payload["created_surface"] == .bool(false))
        #expect(payload["sent_command"] == .bool(true))
        #expect(payload["command_queued"] == .bool(false))
        #expect(payload["surface_visible"] == .bool(true))
        #expect(payload["surface_health_in_window"] == .bool(true))
        #expect(payload["surface_window_event_observed"] == .null)
        #expect(context.paneCreateCalls.isEmpty)
        #expect(context.surfaceCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.count == 1)
        #expect(context.surfaceSendTextCalls.first?.routing.workspaceID == context.focusedWorkspaceID)
        #expect(context.surfaceSendTextCalls.first?.surfaceID == context.helperSurfaceID)
        #expect(context.surfaceSendTextCalls.first?.text == "echo helper\n")
        #expect(context.surfaceHealthRoutings.count == 2)
    }

    @Test func visibleHelperSendsCommandToSelectedHelperSurfaceWhenPaneHasMultipleSurfaces() async throws {
        let (coordinator, context) = makeCoordinator()
        context.includeExistingHelperPane = true
        context.includeExtraHelperSurface = true

        let result = await coordinator.handleHelperAsync(request([
            "initial_command": .string("echo selected"),
        ]))

        guard case .ok(.object(let payload)) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }

        #expect(payload["pane_id"] == .string(context.helperPaneID.uuidString))
        #expect(payload["surface_id"] == .string(context.helperSurfaceID.uuidString))
        #expect(payload["sent_command"] == .bool(true))
        #expect(context.paneCreateCalls.isEmpty)
        #expect(context.surfaceCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.count == 1)
        #expect(context.surfaceSendTextCalls.first?.surfaceID == context.helperSurfaceID)
        #expect(context.surfaceSendTextCalls.first?.surfaceID != context.extraHelperSurfaceID)
    }

    @Test func visibleHelperReusesVisibleRequestedSurfaceWhenSelectedSurfaceIsNotVisible() async throws {
        let (coordinator, context) = makeCoordinator()
        context.includeExistingHelperPane = true
        context.includeExtraHelperSurface = true
        context.existingHelperSurfaceVisible = false

        let result = await coordinator.handleHelperAsync(request([
            "initial_command": .string("echo visible extra"),
        ]))

        guard case .ok(.object(let payload)) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }

        #expect(payload["pane_id"] == .string(context.helperPaneID.uuidString))
        #expect(payload["surface_id"] == .string(context.extraHelperSurfaceID.uuidString))
        #expect(payload["placement_strategy"] == .string("reused_right_pane"))
        #expect(payload["reused_pane"] == .bool(true))
        #expect(payload["created_pane"] == .bool(false))
        #expect(payload["sent_command"] == .bool(true))
        #expect(context.paneCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.count == 1)
        #expect(context.surfaceSendTextCalls.first?.surfaceID == context.extraHelperSurfaceID)
    }

    @Test func visibleHelperDoesNotReuseVisibleNonRightPane() async throws {
        let (coordinator, context) = makeCoordinator()
        context.includeLeftPane = true
        context.includeExistingHelperPane = true
        context.helperSurfaceTypeRaw = "browser"

        let result = await coordinator.handleHelperAsync(request([
            "type": .string("terminal"),
        ]))

        guard case .ok(.object(let payload)) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }

        #expect(payload["pane_id"] == .string(context.createdPaneID.uuidString))
        #expect(payload["surface_id"] == .string(context.createdSurfaceID.uuidString))
        #expect(payload["placement_strategy"] == .string("created_right_pane"))
        #expect(payload["reused_pane"] == .bool(false))
        #expect(payload["created_pane"] == .bool(true))
        #expect(context.paneCreateCalls.count == 1)
        #expect(context.surfaceSendTextCalls.isEmpty)
    }

    @Test func visibleHelperWrongTypeInvisiblePaneDoesNotBlockRequestedTypeCreation() async throws {
        let (coordinator, context) = makeCoordinator()
        context.includeExistingHelperPane = true
        context.existingHelperSurfaceVisible = false
        context.helperSurfaceTypeRaw = "browser"

        let result = await coordinator.handleHelperAsync(request([
            "type": .string("terminal"),
        ]))

        guard case .ok(.object(let payload)) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }

        #expect(payload["pane_id"] == .string(context.createdPaneID.uuidString))
        #expect(payload["surface_id"] == .string(context.createdSurfaceID.uuidString))
        #expect(payload["placement_strategy"] == .string("created_right_pane"))
        #expect(payload["created_pane"] == .bool(true))
        #expect(context.paneCreateCalls.count == 1)
    }

    @Test func visibleHelperRejectsStructuralHelperPaneThatIsNotVisible() async throws {
        let (coordinator, context) = makeCoordinator()
        context.includeExistingHelperPane = true
        context.existingHelperSurfaceVisible = false

        let result = await coordinator.handleHelperAsync(request())

        guard case .err(let code, let message, let data) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }
        guard case .object(let payload)? = data else {
            Issue.record("unexpected helper.visible error data: \(String(describing: data))")
            return
        }

        #expect(code == "not_visible")
        #expect(message.contains("structural helper pane"))
        #expect(payload["workspace_id"] == .string(context.focusedWorkspaceID.uuidString))
        #expect(payload["pane_id"] == .string(context.helperPaneID.uuidString))
        #expect(payload["target_workspace_source"] == .string("focused"))
        #expect(context.paneCreateCalls.isEmpty)
        #expect(context.surfaceCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.isEmpty)
        #expect(context.surfaceHealthRoutings.count == 1)
    }

    @Test func visibleHelperCommandSendFailureUsesCommandFailedCode() async throws {
        let (coordinator, context) = makeCoordinator()
        context.includeExistingHelperPane = true
        context.surfaceSendTextFails = true

        let result = await coordinator.handleHelperAsync(request([
            "initial_command": .string("echo fails"),
        ]))

        guard case .err(let code, let message, let data) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }
        guard case .object(let payload)? = data else {
            Issue.record("unexpected helper.visible error data: \(String(describing: data))")
            return
        }

        #expect(code == "command_failed")
        #expect(message.contains("failed to send"))
        #expect(payload["surface_visible"] == .bool(true))
        #expect(payload["surface_health_in_window"] == .bool(true))
        #expect(payload["sent_command"] == .bool(false))
        #expect(context.paneCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.count == 1)
    }

    @Test func visibleHelperFailsWhenCreatedSurfaceIsNotInWindow() async throws {
        let (coordinator, context) = makeCoordinator()
        context.createdSurfaceVisible = false

        let result = await coordinator.handleHelperAsync(request())

        guard case .err(let code, let message, let data) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }
        guard case .object(let payload)? = data else {
            Issue.record("unexpected helper.visible error data: \(String(describing: data))")
            return
        }

        #expect(code == "not_visible")
        #expect(message.contains("in_window=true"))
        #expect(payload["workspace_id"] == .string(context.focusedWorkspaceID.uuidString))
        #expect(payload["surface_id"] == .string(context.createdSurfaceID.uuidString))
        #expect(payload["placement_strategy"] == .string("created_right_pane"))
        #expect(payload["surface_visible"] == .bool(false))
        #expect(payload["surface_health_found"] == .bool(true))
        #expect(payload["surface_health_in_window"] == .bool(false))
        #expect(payload["surface_health_attempts"] == .int(1))
        #expect(payload["surface_window_event_observed"] == .bool(true))
        #expect(context.paneCreateCalls.count == 1)
        #expect(context.surfaceCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.isEmpty)
        #expect(context.surfaceHealthRoutings.count == 2)
        #expect(context.surfaceWindowWaits.count == 1)
    }
}
