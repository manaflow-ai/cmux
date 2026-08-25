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
                + "--clear-status --require-owned-key "
                + "--runtime-key=omp.~cmux-session-v1~.c2Vzc2lvbi1h "
                + "--runtime-generation=123.5"
        )

        #expect(response == "OK")
        #expect(context.agentPIDClearCall?.target == .workspace(workspaceID))
        #expect(context.agentPIDClearCall?.key == "omp.stale")
        #expect(context.agentPIDClearCall?.panelID == panelID)
        #expect(context.agentPIDClearCall?.clearStatus == true)
        #expect(context.agentPIDClearCall?.requireOwnedKey == true)
        #expect(
            context.agentPIDClearCall?.runtimeKey
                == "omp.~cmux-session-v1~.c2Vzc2lvbi1h"
        )
        #expect(context.agentPIDClearCall?.runtimeGeneration == 123.5)
    }

    @Test func agentStatusAndLifecycleForwardRuntimeAuthority() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()
        let panelID = UUID()
        let runtimeKey = "omp.~cmux-session-v1~.c2Vzc2lvbi1h"

        let statusResponse = coordinator.handleSidebarV1(
            command: "set_status",
            args: "omp Running --tab=\(workspaceID.uuidString) "
                + "--panel=\(panelID.uuidString) --runtime-key=\(runtimeKey) "
                + "--runtime-generation=123.5"
        )
        let pidResponse = coordinator.handleSidebarV1(
            command: "set_agent_pid",
            args: "\(runtimeKey) 123 --tab=\(workspaceID.uuidString) "
                + "--panel=\(panelID.uuidString) --runtime-key=\(runtimeKey) "
                + "--runtime-generation=123.5"
        )
        let lifecycleResponse = coordinator.handleSidebarV1(
            command: "set_agent_lifecycle",
            args: "omp running --tab=\(workspaceID.uuidString) "
                + "--panel=\(panelID.uuidString) --runtime-key=\(runtimeKey) "
                + "--runtime-generation=123.5"
        )

        #expect(statusResponse == "OK")
        #expect(context.statusUpsertCall?.target == .workspace(workspaceID))
        #expect(context.statusUpsertCall?.key == "omp")
        #expect(context.statusUpsertCall?.panelID == panelID)
        #expect(context.statusUpsertCall?.runtimeKey == runtimeKey)
        #expect(context.statusUpsertCall?.runtimeGeneration == 123.5)
        #expect(pidResponse == "OK")
        #expect(context.agentPIDRecordCall?.target == .workspace(workspaceID))
        #expect(context.agentPIDRecordCall?.key == runtimeKey)
        #expect(context.agentPIDRecordCall?.panelID == panelID)
        #expect(context.agentPIDRecordCall?.runtimeKey == runtimeKey)
        #expect(context.agentPIDRecordCall?.runtimeGeneration == 123.5)
        #expect(lifecycleResponse == "OK")
        #expect(context.agentLifecycleCall?.target == .workspace(workspaceID))
        #expect(context.agentLifecycleCall?.key == "omp")
        #expect(context.agentLifecycleCall?.panelID == panelID)
        #expect(context.agentLifecycleCall?.runtimeKey == runtimeKey)
        #expect(context.agentLifecycleCall?.runtimeGeneration == 123.5)
    }

    @Test(arguments: ["0", "-1", "nan", "inf"])
    func agentRuntimeCommandsRejectInvalidGeneration(rawGeneration: String) {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let response = coordinator.handleSidebarV1(
            command: "set_agent_pid",
            args: "omp.session 123 --runtime-key=omp.session "
                + "--runtime-generation=\(rawGeneration)"
        )

        #expect(response == "Invalid runtime generation; expected a finite positive number")
        #expect(context.agentPIDRecordCall == nil)
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
