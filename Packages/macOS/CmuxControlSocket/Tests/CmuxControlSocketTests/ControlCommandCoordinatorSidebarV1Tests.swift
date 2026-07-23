import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator sidebar v1 dispatch")
struct ControlCommandCoordinatorSidebarV1Tests {
    @Test func conditionalNeedsInputFlagRejectsNonRunningLifecycle() {
        let coordinator = ControlCommandCoordinator(context: FakeSidebarV1ControlCommandContext())

        let response = coordinator.handleSidebarV1(
            command: "set_agent_lifecycle",
            args: "codex idle --tab=workspace-1 --if-needs-input"
        )

        #expect(response?.contains("Invalid agent lifecycle 'idle'") == true)
        #expect(response?.contains("[--if-needs-input]") == true)
    }

    @Test func orderedLifecycleRequiresACompleteRuntimeGeneration() {
        let coordinator = ControlCommandCoordinator(context: FakeSidebarV1ControlCommandContext())

        let incomplete = coordinator.handleSidebarV1(
            command: "set_agent_lifecycle",
            args: "codex running --tab=workspace-1 --runtime-key=codex.session --status-revision=2"
        )
        let complete = coordinator.handleSidebarV1(
            command: "set_agent_lifecycle",
            args: "codex running --tab=workspace-1 --runtime-key=codex.session --runtime-pid=4242 --status-revision=2"
        )

        #expect(incomplete?.contains("--runtime-key=<key> --runtime-pid=<pid> --status-revision=<n>") == true)
        #expect(complete == "OK")
    }

    @Test func notificationCleanupRequiresAConditionalResume() {
        let coordinator = ControlCommandCoordinator(context: FakeSidebarV1ControlCommandContext())

        let response = coordinator.handleSidebarV1(
            command: "set_agent_lifecycle",
            args: "codex running --tab=workspace-1 --clear-notifications-if-resumed"
        )

        #expect(response?.contains("Invalid agent lifecycle 'running'") == true)
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
