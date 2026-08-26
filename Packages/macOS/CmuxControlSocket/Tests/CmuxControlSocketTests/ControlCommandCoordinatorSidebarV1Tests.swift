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

    @Test func anonymousLifecycleMutationsForwardProcessGenerationGuards() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()
        let panelID = UUID()

        let pidResponse = coordinator.handleSidebarV1(
            command: "set_agent_pid",
            args: "kiro.surface 43210 --tab=\(workspaceID.uuidString) "
                + "--panel=\(panelID.uuidString) "
                + "--expected-pid-start-seconds=123 --expected-pid-start-microseconds=456"
        )
        #expect(pidResponse == "OK")
        #expect(context.agentPIDRecordCall?.target == .workspace(workspaceID))
        #expect(context.agentPIDRecordCall?.key == "kiro.surface")
        #expect(context.agentPIDRecordCall?.pid == 43_210)
        #expect(context.agentPIDRecordCall?.panelID == panelID)
        #expect(context.agentPIDRecordCall?.expectedPIDStartSeconds == 123)
        #expect(context.agentPIDRecordCall?.expectedPIDStartMicroseconds == 456)

        let lifecycleResponse = coordinator.handleSidebarV1(
            command: "set_agent_lifecycle",
            args: "kiro running --tab=\(workspaceID.uuidString) "
                + "--panel=\(panelID.uuidString) --expected-pid-key=kiro.surface "
                + "--expected-pid=43210 --expected-pid-start-seconds=123 "
                + "--expected-pid-start-microseconds=456"
        )
        #expect(lifecycleResponse == "OK")
        #expect(context.agentLifecycleCall?.expectedPIDKey == "kiro.surface")
        #expect(context.agentLifecycleCall?.expectedPID == 43_210)
        #expect(context.agentLifecycleCall?.expectedPIDStartSeconds == 123)
        #expect(context.agentLifecycleCall?.expectedPIDStartMicroseconds == 456)
    }

    @Test func lifecycleAcceptanceOptionReturnsAppliedOwnerResult() {
        let workspaceID = UUID()
        let panelID = UUID()

        for accepted in [true, false] {
            let context = FakeSidebarV1ControlCommandContext()
            context.agentLifecycleAccepted = accepted
            let coordinator = ControlCommandCoordinator(context: context)
            let response = coordinator.handleSidebarV1(
                command: "set_agent_lifecycle",
                args: "kiro unknown --tab=\(workspaceID.uuidString) "
                    + "--panel=\(panelID.uuidString) --new-occupant "
                    + "--expected-pid-key=kiro.surface --expected-pid=43210 "
                    + "--expected-pid-start-seconds=123 "
                    + "--expected-pid-start-microseconds=456 --require-accepted"
            )

            #expect(response == (accepted ? "OK:1" : "OK:0"))
            #expect(context.agentLifecycleCall?.target == .workspace(workspaceID))
            #expect(context.agentLifecycleCall?.panelID == panelID)
            #expect(context.agentLifecycleCall?.startsNewOccupant == true)
        }
    }

    @Test func lifecycleAcceptanceCanPreserveVisibleNotifications() {
        let workspaceID = UUID()
        let panelID = UUID()

        for preserve in [false, true] {
            let context = FakeSidebarV1ControlCommandContext()
            let coordinator = ControlCommandCoordinator(context: context)
            let preserveOption = preserve ? " --preserve-notifications" : ""
            let response = coordinator.handleSidebarV1(
                command: "set_agent_lifecycle",
                args: "kiro unknown --tab=\(workspaceID.uuidString) "
                    + "--panel=\(panelID.uuidString) --new-occupant "
                    + "--expected-pid-key=kiro.surface --expected-pid=43210 "
                    + "--expected-pid-start-seconds=123 "
                    + "--expected-pid-start-microseconds=456 --require-accepted"
                    + preserveOption
            )

            #expect(response == "OK:1")
            #expect(context.agentLifecycleClearNotifications == !preserve)
        }
    }

    @Test func clearAgentPIDRequireClearedReturnsAppliedOwnerResult() {
        let workspaceID = UUID()
        let panelID = UUID()

        for accepted in [true, false] {
            let context = FakeSidebarV1ControlCommandContext()
            context.agentPIDClearAccepted = accepted
            let coordinator = ControlCommandCoordinator(context: context)
            let response = coordinator.handleSidebarV1(
                command: "clear_agent_pid",
                args: "omp.session-1 --tab=\(workspaceID.uuidString) "
                    + "--panel=\(panelID.uuidString) --clear-status "
                    + "--session-id=session-1 --require-cleared"
            )

            #expect(response == (accepted ? "OK:1" : "OK:0"))
            #expect(context.agentPIDClearCall?.target == .workspace(workspaceID))
            #expect(context.agentPIDClearCall?.panelID == panelID)
            #expect(context.agentPIDClearCall?.expectedLifecycleSessionID == "session-1")
        }
    }

    @Test func anonymousLifecycleMutationsRejectPartialProcessGenerations() {
        for option in [
            "--expected-pid-start-seconds=123",
            "--expected-pid-start-microseconds=456",
        ] {
            let pidContext = FakeSidebarV1ControlCommandContext()
            let pidCoordinator = ControlCommandCoordinator(context: pidContext)
            let pidResponse = pidCoordinator.handleSidebarV1(
                command: "set_agent_pid",
                args: "kiro.surface 43210 \(option)"
            )
            #expect(pidResponse.hasPrefix("ERROR: Usage:"))
            #expect(pidContext.agentPIDRecordCall == nil)

            let lifecycleContext = FakeSidebarV1ControlCommandContext()
            let lifecycleCoordinator = ControlCommandCoordinator(context: lifecycleContext)
            let lifecycleResponse = lifecycleCoordinator.handleSidebarV1(
                command: "set_agent_lifecycle",
                args: "kiro running --expected-pid-key=kiro.surface --expected-pid=43210 \(option)"
            )
            #expect(lifecycleResponse.hasPrefix("ERROR: Usage:"))
            #expect(lifecycleContext.agentLifecycleCall == nil)
        }
    }

    @Test func statusUpsertForwardsCompleteAgentMutationGuards() {
        let workspaceID = UUID()
        let panelID = UUID()
        let cases: [(options: String, expected: ControlSidebarAgentMutationGuard)] = [
            (
                "--expected-agent-key=kiro --expected-agent-session-id=session-1",
                .session(statusKey: "kiro", sessionID: "session-1")
            ),
            (
                "--expected-agent-key=kiro --expected-agent-pid-key=kiro.surface "
                    + "--expected-agent-pid=43210 --expected-agent-pid-start-seconds=123 "
                    + "--expected-agent-pid-start-microseconds=456",
                .process(
                    statusKey: "kiro",
                    pidKey: "kiro.surface",
                    pid: 43_210,
                    startSeconds: 123,
                    startMicroseconds: 456
                )
            ),
        ]

        for testCase in cases {
            let context = FakeSidebarV1ControlCommandContext()
            let coordinator = ControlCommandCoordinator(context: context)
            let response = coordinator.handleSidebarV1(
                command: "set_status",
                args: "kiro Running --tab=\(workspaceID.uuidString) "
                    + "--panel=\(panelID.uuidString) \(testCase.options)"
            )

            #expect(response == "OK")
            #expect(context.statusUpsertCall?.target == .workspace(workspaceID))
            #expect(context.statusUpsertCall?.key == "kiro")
            #expect(context.statusUpsertCall?.value == "Running")
            #expect(context.statusUpsertCall?.panelID == panelID)
            #expect(context.statusUpsertCall?.agentMutationGuard == testCase.expected)
        }
    }

    @Test func statusUpsertRejectsPartialOrMismatchedAgentMutationGuards() {
        let invalidOptions = [
            "--expected-agent-session-id=session-1",
            "--expected-agent-key=codex --expected-agent-session-id=session-1",
            "--expected-agent-key=kiro --expected-agent-pid-key=kiro.surface "
                + "--expected-agent-pid=43210 --expected-agent-pid-start-seconds=123",
        ]

        for options in invalidOptions {
            let context = FakeSidebarV1ControlCommandContext()
            let coordinator = ControlCommandCoordinator(context: context)
            let response = coordinator.handleSidebarV1(
                command: "set_status",
                args: "kiro Running \(options)"
            )

            #expect(response.hasPrefix("ERROR: Usage:"))
            #expect(context.statusUpsertCall == nil)
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

    @Test func shellStateForwardsTerminalLifecycleScope() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()
        let panelID = UUID()
        let terminalLifecycleID = UUID()

        let response = coordinator.handleSidebarV1(
            command: "report_shell_state",
            args: "prompt --tab=\(workspaceID.uuidString) "
                + "--panel=\(panelID.uuidString) "
                + "--terminal-lifecycle-id=\(terminalLifecycleID.uuidString)"
        )

        #expect(response == "OK")
        #expect(context.shellStateCall?.scope.workspaceID == workspaceID)
        #expect(context.shellStateCall?.scope.panelID == panelID)
        #expect(
            context.shellStateCall?.scope.terminalLifecycleID
                == terminalLifecycleID
        )
        #expect(context.shellStateCall?.stateRawValue == "promptIdle")
    }

    @Test func shellStateRejectsMalformedTerminalLifecycleScope() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let response = coordinator.handleSidebarV1(
            command: "report_shell_state",
            args: "prompt --tab=\(UUID().uuidString) "
                + "--panel=\(UUID().uuidString) "
                + "--terminal-lifecycle-id=not-a-uuid"
        )

        #expect(response == "ERROR: Terminal session is out of date; restart the shell and try again")
        #expect(context.shellStateCall == nil)
    }

    @Test func shellStateRejectsLifecycleIdentityWithoutCompleteScope() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let response = coordinator.handleSidebarV1(
            command: "report_shell_state",
            args: "prompt --tab=\(UUID().uuidString) "
                + "--terminal-lifecycle-id=\(UUID().uuidString)"
        )

        #expect(response == "ERROR: Terminal session is out of date; restart the shell and try again")
        #expect(context.shellStateCall == nil)
    }
}
