import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator sidebar v1 dispatch")
struct ControlCommandCoordinatorSidebarV1Tests {
    @Test func agentPIDAndLifecycleForwardExactProcessGeneration() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()
        let panelID = UUID()
        let generationOptions =
            "--pid=4242 --pid-start-seconds=100 "
            + "--pid-start-microseconds=200"

        let pidResponse = coordinator.handleSidebarV1(
            command: "set_agent_pid",
            args:
                "codex.session 4242 --tab=\(workspaceID.uuidString) "
                + "--panel=\(panelID.uuidString) \(generationOptions)"
        )
        let lifecycleResponse = coordinator.handleSidebarV1(
            command: "set_agent_lifecycle",
            args:
                "codex idle --tab=\(workspaceID.uuidString) "
                + "--panel=\(panelID.uuidString) \(generationOptions)"
        )

        #expect(pidResponse == "OK")
        #expect(lifecycleResponse == "OK")
        #expect(
            context.agentPIDRecordCall?.processGeneration
                == ControlSidebarAgentProcessGeneration(
                    pid: 4242,
                    startSeconds: 100,
                    startMicroseconds: 200
                )
        )
        #expect(
            context.agentLifecycleCall?.processGeneration
                == ControlSidebarAgentProcessGeneration(
                    pid: 4242,
                    startSeconds: 100,
                    startMicroseconds: 200
                )
        )
    }

    @Test func agentPIDRejectsMismatchedProcessGenerationPID() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()

        let response = coordinator.handleSidebarV1(
            command: "set_agent_pid",
            args:
                "codex 4243 --tab=\(workspaceID.uuidString) "
                + "--pid=4242 --pid-start-seconds=100 "
                + "--pid-start-microseconds=200"
        )

        #expect(
            response
                == "ERROR: Agent process generation PID does not match <pid>"
        )
        #expect(context.agentPIDRecordCall == nil)
    }

    @Test func partialAgentProcessGenerationIsRejected() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()

        let response = coordinator.handleSidebarV1(
            command: "set_agent_lifecycle",
            args:
                "codex idle --tab=\(workspaceID.uuidString) "
                + "--pid=4242 --pid-start-seconds=100"
        )

        #expect(
            response?.hasPrefix(
                "ERROR: Invalid agent process generation"
            ) == true
        )
        #expect(context.agentLifecycleCall == nil)
    }

    @Test func localBuiltInLifecycleRequiresExactProcessGeneration() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()

        let response = coordinator.handleSidebarV1(
            command: "set_agent_lifecycle",
            args:
                "codex running --tab=\(workspaceID.uuidString)"
        )

        #expect(
            response
                == "ERROR: Agent process generation is required for 'codex'"
        )
        #expect(context.agentLifecycleCall == nil)
    }

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
