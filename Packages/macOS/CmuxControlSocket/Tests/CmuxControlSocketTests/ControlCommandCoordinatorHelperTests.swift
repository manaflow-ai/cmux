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

    @Test func visibleHelperRejectsOffscreenTargetBeforeCreatingPane() async throws {
        let (coordinator, context) = makeCoordinator()
        context.focusedSurfaceVisible = false

        let result = await coordinator.handleHelperAsync(request([
            "initial_command": .string("echo should-not-create"),
        ]))

        guard case .err(let code, let message, let data) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }
        guard case .object(let payload)? = data else {
            Issue.record("unexpected helper.visible error data: \(String(describing: data))")
            return
        }

        #expect(code == "not_visible")
        #expect(message.contains("target workspace is visible"))
        #expect(payload["workspace_id"] == .string(context.focusedWorkspaceID.uuidString))
        #expect(payload["target_surface_visible"] == .bool(false))
        #expect(payload["visibility_source"] == .string("surface.health"))
        #expect(context.paneCreateCalls.isEmpty)
        #expect(context.surfaceCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.isEmpty)
        #expect(context.surfaceWindowWaits.isEmpty)
    }

    @Test func visibleHelperRejectsHiddenWindowBeforeCreatingPane() async throws {
        let (coordinator, context) = makeCoordinator()
        context.windowVisible = false

        let result = await coordinator.handleHelperAsync(request([
            "initial_command": .string("echo should-not-create"),
        ]))

        guard case .err(let code, let message, let data) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }
        guard case .object(let payload)? = data else {
            Issue.record("unexpected helper.visible error data: \(String(describing: data))")
            return
        }

        #expect(code == "not_visible")
        #expect(message.contains("target workspace is visible"))
        #expect(payload["workspace_id"] == .string(context.focusedWorkspaceID.uuidString))
        #expect(payload["target_surface_visible"] == .bool(false))
        if case .object(let health)? = payload["surface_health"] {
            #expect(health["window_visible"] == .bool(false))
        } else {
            Issue.record("missing surface_health payload")
        }
        #expect(context.paneCreateCalls.isEmpty)
        #expect(context.surfaceCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.isEmpty)
        #expect(context.surfaceWindowWaits.isEmpty)
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

    @Test func visibleHelperRejectsPaneWhenSelectedSurfaceIsNotVisible() async throws {
        let (coordinator, context) = makeCoordinator()
        context.includeExistingHelperPane = true
        context.includeExtraHelperSurface = true
        context.existingHelperSurfaceVisible = false

        let result = await coordinator.handleHelperAsync(request([
            "initial_command": .string("echo visible extra"),
        ]))

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
        #expect(payload["pane_id"] == .string(context.helperPaneID.uuidString))
        #expect(payload["target_workspace_source"] == .string("focused"))
        #expect(context.paneCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.isEmpty)
    }

    @Test func visibleHelperRejectsMountedButHiddenSelectedHelperSurface() async throws {
        let (coordinator, context) = makeCoordinator()
        context.includeExistingHelperPane = true
        context.existingHelperSurfaceVisible = true
        context.existingHelperSurfaceVisibleInUI = false

        let result = await coordinator.handleHelperAsync(request([
            "initial_command": .string("echo hidden"),
        ]))

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
        #expect(payload["pane_id"] == .string(context.helperPaneID.uuidString))
        #expect(context.paneCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.isEmpty)
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

    @Test func visibleHelperRejectsRemoteTmuxTerminalCreateBeforeMutation() async throws {
        let (coordinator, context) = makeCoordinator()
        context.isRemoteTmuxMirror = true

        let result = await coordinator.handleHelperAsync(request([
            "initial_command": .string("echo remote"),
        ]))

        guard case .err(let code, let message, let data) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }
        guard case .object(let payload)? = data else {
            Issue.record("unexpected helper.visible error data: \(String(describing: data))")
            return
        }

        #expect(code == "unsupported")
        #expect(message.contains("remote tmux mirror"))
        #expect(payload["workspace_id"] == .string(context.focusedWorkspaceID.uuidString))
        #expect(payload["target_workspace_source"] == .string("focused"))
        #expect(payload["routed_target"] == .string("remote-tmux"))
        #expect(payload["placement_strategy"] == .string("remote_tmux_rejected_before_mutation"))
        #expect(context.paneCreateCalls.isEmpty)
        #expect(context.surfaceCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.isEmpty)
        #expect(context.surfaceWindowWaits.isEmpty)
    }

    @Test func visibleHelperReusesVisibleRemoteTmuxHelperWithoutCreatingPane() async throws {
        let (coordinator, context) = makeCoordinator()
        context.isRemoteTmuxMirror = true
        context.includeExistingHelperPane = true

        let result = await coordinator.handleHelperAsync(request([
            "initial_command": .string("echo reused remote"),
        ]))

        guard case .ok(.object(let payload)) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }

        #expect(payload["pane_id"] == .string(context.helperPaneID.uuidString))
        #expect(payload["surface_id"] == .string(context.helperSurfaceID.uuidString))
        #expect(payload["reused_pane"] == .bool(true))
        #expect(payload["created_pane"] == .bool(false))
        #expect(payload["surface_visible"] == .bool(true))
        #expect(payload["sent_command"] == .bool(true))
        #expect(context.paneCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.count == 1)
        #expect(context.surfaceSendTextCalls.first?.surfaceID == context.helperSurfaceID)
    }

    @Test func visibleHelperRejectsBrowserDisabledCreateBeforeExternalOpenFallback() async throws {
        let (coordinator, context) = makeCoordinator()
        context.browserCreationDisabled = true

        let result = await coordinator.handleHelperAsync(request([
            "type": .string("browser"),
            "url": .string("https://example.com"),
        ]))

        guard case .err(let code, let message, let data) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }
        guard case .object(let payload)? = data else {
            Issue.record("unexpected helper.visible error data: \(String(describing: data))")
            return
        }

        #expect(code == "browser_disabled")
        #expect(message.contains("browser is disabled"))
        #expect(payload["workspace_id"] == .string(context.focusedWorkspaceID.uuidString))
        #expect(payload["mutation_started"] == .bool(false))
        #expect(payload["placement_strategy"] == .string("browser_disabled_rejected_before_mutation"))
        #expect(context.paneCreateCalls.isEmpty)
        #expect(context.surfaceCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.isEmpty)
    }

    @Test func visibleHelperRejectsBrowserCommandBeforeCreatingPane() async throws {
        let (coordinator, context) = makeCoordinator()

        let result = await coordinator.handleHelperAsync(request([
            "type": .string("browser"),
            "initial_command": .string("echo invalid"),
        ]))

        guard case .err(let code, let message, let data) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }
        guard case .object(let payload)? = data else {
            Issue.record("unexpected helper.visible error data: \(String(describing: data))")
            return
        }

        #expect(code == "invalid_params")
        #expect(message.contains("only supported for terminal"))
        #expect(payload["type"] == .string("browser"))
        #expect(payload["mutation_started"] == .bool(false))
        #expect(payload["placement_strategy"] == .string("non_terminal_command_rejected_before_mutation"))
        #expect(context.paneCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.isEmpty)
    }

    @Test func visibleHelperRejectsBrowserURLReuseBeforeMutation() async throws {
        let (coordinator, context) = makeCoordinator()
        context.includeExistingHelperPane = true
        context.helperSurfaceTypeRaw = "browser"

        let result = await coordinator.handleHelperAsync(request([
            "type": .string("browser"),
            "url": .string("https://example.com"),
        ]))

        guard case .err(let code, let message, let data) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }
        guard case .object(let payload)? = data else {
            Issue.record("unexpected helper.visible error data: \(String(describing: data))")
            return
        }

        #expect(code == "unsupported")
        #expect(message.contains("requested URL"))
        #expect(payload["pane_id"] == .string(context.helperPaneID.uuidString))
        #expect(payload["surface_id"] == .string(context.helperSurfaceID.uuidString))
        #expect(payload["mutation_started"] == .bool(false))
        #expect(payload["placement_strategy"] == .string("browser_url_reuse_rejected_before_mutation"))
        #expect(context.paneCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.isEmpty)
    }

    @Test func visibleHelperCancellationBeforeCreateDoesNotMutate() async throws {
        let (coordinator, context) = makeCoordinator()
        let task = Task {
            await coordinator.handleHelperAsync(request([
                "initial_command": .string("echo should-not-create"),
            ]))
        }
        task.cancel()

        let result = await task.value

        guard case .err(let code, let message, let data) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }
        guard case .object(let payload)? = data else {
            Issue.record("unexpected helper.visible error data: \(String(describing: data))")
            return
        }

        #expect(code == "cancelled")
        #expect(message.contains("before creating"))
        #expect(payload["mutation_started"] == .bool(false))
        #expect(payload["placement_strategy"] == .string("cancelled_before_create"))
        #expect(context.paneCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.isEmpty)
    }

    @Test func visibleHelperExpiredMutationDeadlineDoesNotMutate() async throws {
        let (coordinator, context) = makeCoordinator()

        let result = await coordinator.handleHelperAsync(request([
            "_cmux_helper_visible_latest_mutation_start_uptime_ns": .int(1),
            "initial_command": .string("echo should-not-create"),
        ]))

        guard case .err(let code, let message, let data) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }
        guard case .object(let payload)? = data else {
            Issue.record("unexpected helper.visible error data: \(String(describing: data))")
            return
        }

        #expect(code == "timeout")
        #expect(message.contains("before creating"))
        #expect(payload["mutation_started"] == .bool(false))
        #expect(payload["placement_strategy"] == .string("deadline_expired_before_create"))
        #expect(context.paneCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.isEmpty)
    }

    @Test func visibleHelperCancellationAfterVisibilityDoesNotSendCommand() async throws {
        let (coordinator, context) = makeCoordinator()
        nonisolated(unsafe) var task: Task<ControlCallResult?, Never>?
        context.onSurfaceWindowWait = {
            task?.cancel()
        }
        let createdTask = Task {
            await coordinator.handleHelperAsync(request([
                "initial_command": .string("echo should-not-send"),
            ]))
        }
        task = createdTask

        let result = await createdTask.value

        guard case .err(let code, let message, let data) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }
        guard case .object(let payload)? = data else {
            Issue.record("unexpected helper.visible error data: \(String(describing: data))")
            return
        }

        #expect(code == "cancelled")
        #expect(message.contains("before sending"))
        #expect(payload["surface_visible"] == .bool(true))
        #expect(context.paneCreateCalls.count == 1)
        #expect(context.surfaceSendTextCalls.isEmpty)
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

    @Test func visibleHelperFailsWhenCreatedSurfaceWindowEventIsNotObserved() async throws {
        let (coordinator, context) = makeCoordinator()
        context.createdSurfaceVisible = false
        context.createdSurfaceWindowEventObserved = false

        let result = await coordinator.handleHelperAsync(request([
            "initial_command": .string("echo should-not-send"),
        ]))

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
        #expect(payload["surface_window_event_observed"] == .bool(false))
        #expect(payload["sent_command"] == .bool(false))
        #expect(context.paneCreateCalls.count == 1)
        #expect(context.surfaceCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.isEmpty)
        #expect(context.surfaceHealthRoutings.count == 2)
        #expect(context.surfaceWindowWaits.count == 1)
    }
}
