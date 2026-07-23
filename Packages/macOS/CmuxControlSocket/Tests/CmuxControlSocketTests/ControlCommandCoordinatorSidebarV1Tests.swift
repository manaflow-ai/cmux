import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator sidebar v1 dispatch")
struct ControlCommandCoordinatorSidebarV1Tests {
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

    @Test func setStatusRejectsMalformedAgentEventTimeBeforeMutation() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let response = coordinator.handleSidebarV1(
            command: "set_status",
            args: "codex Running --agent-event-time=not-a-time"
        )

        #expect(response == "ERROR: Invalid agent event time 'not-a-time' - must be between 2000-01-01 and 2100-01-01 UTC")
    }

    @Test func setAgentPIDRejectsMalformedAgentEventTimeBeforeMutation() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let response = coordinator.handleSidebarV1(
            command: "set_agent_pid",
            args: "claude_code 42424 --agent-event-time=not-a-time"
        )

        #expect(response == "ERROR: Invalid agent event time 'not-a-time' - must be between 2000-01-01 and 2100-01-01 UTC")
    }

    @Test(arguments: ["1", "1e300", "4102444801"])
    func setStatusRejectsOutOfRangeAgentEventTime(rawEventTime: String) {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let response = coordinator.handleSidebarV1(
            command: "set_status",
            args: "codex Running --agent-event-time=\(rawEventTime)"
        )

        #expect(
            response == "ERROR: Invalid agent event time '\(rawEventTime)' - must be between 2000-01-01 and 2100-01-01 UTC"
        )
    }

    @Test func setStatusRejectsPlausibleEpochThatIsFarInTheFuture() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let response = coordinator.handleSidebarV1(
            command: "set_status",
            args: "codex Running --agent-event-time=4102444800"
        )

        #expect(response?.hasPrefix("ERROR: Invalid agent event time") == true)
    }
}
