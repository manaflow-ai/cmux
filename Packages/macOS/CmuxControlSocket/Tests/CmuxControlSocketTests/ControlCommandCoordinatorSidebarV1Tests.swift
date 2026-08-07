import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator sidebar v1 dispatch")
struct ControlCommandCoordinatorSidebarV1Tests {
    @Test func agentPIDClearForwardsOwnedKeyRequirement() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()
        let panelID = UUID()

        let response = coordinator.handleSidebarV1(
            command: "clear_agent_pid",
            args: "omp.stale --tab=\(workspaceID.uuidString) --panel=\(panelID.uuidString) "
                + "--clear-status --require-owned-key"
        )

        #expect(response == "OK")
        #expect(context.agentPIDClearCall?.target == .workspace(workspaceID))
        #expect(context.agentPIDClearCall?.key == "omp.stale")
        #expect(context.agentPIDClearCall?.panelID == panelID)
        #expect(context.agentPIDClearCall?.clearStatus == true)
        #expect(context.agentPIDClearCall?.requireOwnedKey == true)
    }

    @Test func lifecycleMutationsRejectExplicitlyEmptySessionID() {
        let emptySessionOptions = [
            "--session-id",
            "--session-id=",
            "--session-id='   '",
        ]

        for option in emptySessionOptions {
            let setContext = FakeSidebarV1ControlCommandContext()
            let setCoordinator = ControlCommandCoordinator(context: setContext)
            let setResponse = setCoordinator.handleSidebarV1(
                command: "set_agent_lifecycle",
                args: "claude_code running \(option)"
            )

            #expect(setResponse.hasPrefix("ERROR: Usage:"))
            #expect(setContext.agentLifecycleCall == nil)

            let clearContext = FakeSidebarV1ControlCommandContext()
            let clearCoordinator = ControlCommandCoordinator(context: clearContext)
            let clearResponse = clearCoordinator.handleSidebarV1(
                command: "clear_agent_pid",
                args: "claude_code \(option)"
            )

            #expect(clearResponse.hasPrefix("ERROR: Usage:"))
            #expect(clearContext.agentPIDClearCall == nil)
        }
    }

    @Test func statusClearForwardsPanelScope() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()
        let panelID = UUID()

        let response = coordinator.handleSidebarV1(
            command: "clear_status",
            args: "omp --tab=\(workspaceID.uuidString) --panel=\(panelID.uuidString)"
        )

        #expect(response == "OK")
        #expect(context.statusClearCall?.target == .workspace(workspaceID))
        #expect(context.statusClearCall?.key == "omp")
        #expect(context.statusClearCall?.panelID == panelID)
    }

    @Test func workspaceLoadingFailureReasonReturnsErrorLine() {
        let context = FakeSidebarV1ControlCommandContext()
        context.workspaceLoadingResult = ControlSidebarWorkspaceLoadingState(
            before: false,
            after: false,
            failureReason: "Manual workspace loading limit reached"
        )
        let coordinator = ControlCommandCoordinator(context: context)

        let response = coordinator.handleSidebarV1(
            command: "workspace_loading",
            args: "manual on --tab=workspace-1"
        )

        #expect(response == "ERROR: Manual workspace loading limit reached")
        #expect(context.workspaceLoadingCall?.tabArg == "workspace-1")
        #expect(context.workspaceLoadingCall?.key == "manual")
        #expect(context.workspaceLoadingCall?.on == true)
    }

    @Test func workspaceLoadingRejectsExplicitEmptyTabBeforeMutation() {
        let context = FakeSidebarV1ControlCommandContext()
        context.workspaceLoadingResult = ControlSidebarWorkspaceLoadingState(before: false, after: true)
        let coordinator = ControlCommandCoordinator(context: context)

        let blankForms = [
            "manual on --tab",
            "manual on --tab=",
        ]

        for args in blankForms {
            let response = coordinator.handleSidebarV1(
                command: "workspace_loading",
                args: args
            )

            #expect(response == "ERROR: Invalid --tab; expected a workspace id, ref, or index")
            #expect(context.workspaceLoadingCall == nil)
        }
    }
}
