import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator surface domain")
struct ControlCommandCoordinatorSurfaceTests {
    private func coordinator(
        createResolution: ControlSurfaceCreateResolution
    ) -> (ControlCommandCoordinator, FakeSurfaceControlCommandContext) {
        let context = FakeSurfaceControlCommandContext()
        context.createResolution = createResolution
        return (ControlCommandCoordinator(context: context), context)
    }

    @Test func surfaceCreateDockPayloadUsesDockScopedIDs() throws {
        let windowID = UUID()
        let workspaceID = UUID()
        let dockPaneID = UUID()
        let dockSurfaceID = UUID()
        let (coordinator, context) = coordinator(createResolution: .createdDock(
            windowID: windowID,
            workspaceID: workspaceID,
            dockPaneID: dockPaneID,
            dockSurfaceID: dockSurfaceID,
            typeRawValue: "browser"
        ))

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.create",
            params: [
                "type": .string("browser"),
                "placement": .string("dock"),
            ]
        ))
        _ = context

        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected dock create payload")
            return
        }

        #expect(payload["placement"] == .string("dock"))
        #expect(payload["workspace_id"] == .string(workspaceID.uuidString))
        #expect(payload["window_id"] == .string(windowID.uuidString))
        #expect(payload["surface_id"] == .null)
        #expect(payload["surface_ref"] == .null)
        #expect(payload["pane_id"] == .null)
        #expect(payload["pane_ref"] == .null)
        #expect(payload["dock_surface_id"] == .string(dockSurfaceID.uuidString))
        #expect(payload["dock_pane_id"] == .string(dockPaneID.uuidString))
        #expect(payload["type"] == .string("browser"))
    }

    @Test func paneCreateDockPayloadUsesDockScopedIDs() throws {
        let windowID = UUID()
        let workspaceID = UUID()
        let dockPaneID = UUID()
        let dockSurfaceID = UUID()
        let context = FakeSurfaceControlCommandContext()
        context.paneCreateResolution = .createdDock(
            windowID: windowID,
            workspaceID: workspaceID,
            dockPaneID: dockPaneID,
            dockSurfaceID: dockSurfaceID,
            typeRawValue: "terminal"
        )
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "pane.create",
            params: [
                "direction": .string("right"),
                "placement": .string("dock"),
            ]
        ))

        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected dock pane create payload")
            return
        }

        #expect(payload["placement"] == .string("dock"))
        #expect(payload["workspace_id"] == .string(workspaceID.uuidString))
        #expect(payload["window_id"] == .string(windowID.uuidString))
        #expect(payload["surface_id"] == .null)
        #expect(payload["surface_ref"] == .null)
        #expect(payload["pane_id"] == .null)
        #expect(payload["pane_ref"] == .null)
        #expect(payload["dock_surface_id"] == .string(dockSurfaceID.uuidString))
        #expect(payload["dock_pane_id"] == .string(dockPaneID.uuidString))
        #expect(payload["type"] == .string("terminal"))
    }

    @Test func paneBreakRejectsExplicitNullSurfaceID() {
        let context = FakeSurfaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "pane.break",
            params: ["surface_id": .null]
        ))

        #expect(result == .err(code: "not_found", message: "Surface not found", data: nil))
    }

    @Test func paneJoinRejectsExplicitNullSurfaceID() {
        let context = FakeSurfaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "pane.join",
            params: [
                "target_pane_id": .string(UUID().uuidString),
                "surface_id": .null,
            ]
        ))

        #expect(result == .err(code: "not_found", message: "Surface not found", data: nil))
    }

    @Test func surfaceCreateRemotePayloadIdentifiesTmuxNewWindow() throws {
        let workspaceID = UUID()
        let (coordinator, context) = coordinator(createResolution: .routedToRemote(
            windowID: nil,
            workspaceID: workspaceID,
            typeRawValue: "terminal"
        ))

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.create",
            params: ["type": .string("terminal")]
        ))
        _ = context

        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected routed remote create payload")
            return
        }

        #expect(payload["accepted"] == .bool(true))
        #expect(payload["routed"] == .string("remote-tmux"))
        #expect(payload["remote_tmux_operation"] == .string("new-window"))
        #expect(payload["workspace_id"] == .string(workspaceID.uuidString))
    }

    @Test func surfaceCreateDockUnsupportedTypeReturnsInvalidParams() throws {
        let (coordinator, context) = coordinator(createResolution: .dockUnsupportedType(
            typeRawValue: "agentSession",
            message: "Dock placement supports only terminal and browser surfaces"
        ))
        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.create",
            params: [
                "type": .string("agent-session"),
                "placement": .string("dock"),
            ]
        ))
        _ = context

        guard case .err(let code, let message, let data) = result else {
            Issue.record("expected invalid_params error")
            return
        }

        #expect(code == "invalid_params")
        #expect(message == "Dock placement supports only terminal and browser surfaces")
        #expect(data == .object(["type": .string("agentSession")]))
    }

    @Test func surfaceCloseRejectsUnresolvedExplicitSurfaceRef() {
        let context = FakeSurfaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.close",
            params: [
                "workspace_id": .string(UUID().uuidString),
                "surface_id": .string("surface:99999"),
            ]
        ))

        #expect(result == .err(code: "not_found", message: "Surface not found", data: nil))
    }

    @Test func surfaceCloseRejectsExplicitNullSurfaceID() {
        let context = FakeSurfaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.close",
            params: [
                "workspace_id": .string(UUID().uuidString),
                "surface_id": .null,
            ]
        ))

        #expect(result == .err(code: "not_found", message: "Surface not found", data: nil))
    }

    @Test func surfaceRespawnRejectsUnresolvedExplicitSurfaceRef() {
        let context = FakeSurfaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.respawn",
            params: [
                "workspace_id": .string(UUID().uuidString),
                "surface_id": .string("surface:99999"),
                "command": .string("echo nope"),
            ]
        ))

        guard case .err(let code, _, let data) = result else {
            Issue.record("expected not_found error")
            return
        }
        #expect(code == "not_found")
        #expect(data == nil)
    }

    @Test func surfaceRespawnRejectsExplicitNullSurfaceID() {
        let context = FakeSurfaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.respawn",
            params: [
                "workspace_id": .string(UUID().uuidString),
                "surface_id": .null,
                "command": .string("echo nope"),
            ]
        ))

        guard case .err(let code, _, let data) = result else {
            Issue.record("expected not_found error")
            return
        }
        #expect(code == "not_found")
        #expect(data == nil)
    }

    @Test func surfaceListIncludesLiveSimulatorIdentity() throws {
        let context = FakeSurfaceControlCommandContext()
        let workspaceID = UUID()
        let surfaceID = UUID()
        context.surfaceListSnapshot = ControlSurfaceListSnapshot(
            workspaceID: workspaceID,
            windowID: nil,
            surfaces: [ControlSurfaceSummary(
                surfaceID: surfaceID,
                typeRawValue: "simulator",
                title: "Simulator",
                isFocused: true,
                paneID: nil,
                indexInPane: nil,
                selectedInPane: nil,
                developerToolsVisible: nil,
                requestedWorkingDirectory: nil,
                initialCommand: nil,
                tmuxStartCommand: nil,
                isTerminal: false,
                resumeBinding: nil,
                simulatorDeviceID: "SIM-UDID",
                simulatorRuntimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
                simulatorDeviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5",
                simulatorDeviceName: "iPad Pro 13-inch (M5)",
                simulatorDeviceState: "Booted"
            )]
        )
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.list",
            params: ["workspace_id": .string(workspaceID.uuidString)]
        ))

        guard case let .ok(.object(payload)) = result,
              case let .array(rows)? = payload["surfaces"],
              case let .object(row)? = rows.first else {
            Issue.record("Expected a Simulator surface row")
            return
        }
        #expect(row["simulator_id"] == .string("SIM-UDID"))
        #expect(row["device_name"] == .string("iPad Pro 13-inch (M5)"))
        #expect(row["state"] == .string("Booted"))
    }

    @Test func surfaceListIncludesFilePathWhenAvailable() throws {
        let context = FakeSurfaceControlCommandContext()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let filePath = "/tmp/project/nested/source.swift"
        context.surfaceListSnapshot = ControlSurfaceListSnapshot(
            workspaceID: workspaceID,
            windowID: nil,
            surfaces: [ControlSurfaceSummary(
                surfaceID: surfaceID,
                typeRawValue: "filepreview",
                title: "source.swift",
                filePath: filePath,
                isFocused: true,
                paneID: nil,
                indexInPane: nil,
                selectedInPane: nil,
                developerToolsVisible: nil,
                requestedWorkingDirectory: nil,
                initialCommand: nil,
                tmuxStartCommand: nil,
                isTerminal: false,
                resumeBinding: nil
            )]
        )
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.list",
            params: ["workspace_id": .string(workspaceID.uuidString)]
        ))

        guard case let .ok(.object(payload)) = result,
              case let .array(rows)? = payload["surfaces"],
              case let .object(row)? = rows.first else {
            Issue.record("Expected a file-preview surface row")
            return
        }
        #expect(row["file_path"] == .string(filePath))
    }

    @Test func surfaceResumePendingApprovalReturnsRetryableBusyError() {
        let context = FakeSurfaceControlCommandContext()
        let message = "Resume approval data is still loading. Retry the request."
        context.resumeResolution = .approvalPending(message: message)
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.resume.set",
            params: ["command": .string("tmux attach -t work")]
        ))

        #expect(result == .err(
            code: "busy",
            message: message,
            data: .object(["retryable": .bool(true)])
        ))
    }

    @Test func surfaceResumeSetKeepsStructuredLaunchDataStructured() throws {
        let context = FakeSurfaceControlCommandContext()
        context.resumeResolution = .setFailed
        let coordinator = ControlCommandCoordinator(context: context)

        _ = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.resume.set",
            params: [
                "command": .string("codex resume legacy"),
                "kind": .string("codex"),
                "source": .string("agent-hook"),
                "permission_mode": .string("never"),
                "launch_command": .object([
                    "launcher": .string("codex"),
                    "executable_path": .string("/opt/Codex Tools/codex"),
                    "arguments": .array([
                        .string("/opt/Codex Tools/codex"),
                        .string("space value"),
                        .string("引用"),
                    ]),
                    "working_directory": .string("/tmp/项目"),
                    "environment": .object(["CODEX_HOME": .string("/tmp/配置")]),
                    "verification_home": .string("/tmp/launch-user"),
                    "captured_at": .double(42.5),
                    "source": .string("test"),
                ]),
                "resume_evidence_provenance": .string("tui"),
            ]
        ))

        let inputs = try #require(context.resumeSetInputs)
        #expect(inputs.permissionMode == "never")
        #expect(inputs.source == "agent-hook")
        #expect(inputs.launchCommand == ControlAgentLaunchCommand(
            launcher: "codex",
            executablePath: "/opt/Codex Tools/codex",
            arguments: ["/opt/Codex Tools/codex", "space value", "引用"],
            workingDirectory: "/tmp/项目",
            environment: ["CODEX_HOME": "/tmp/配置"],
            verificationHome: "/tmp/launch-user",
            capturedAt: 42.5,
            source: "test"
        ))
        #expect(inputs.resumeEvidenceProvenance == "tui")
    }

    @Test(
        "surface resume set rejects malformed structured launch data",
        arguments: [
            JSONValue.string("codex"),
            .object([:]),
            .object(["arguments": .array([])]),
            .object(["arguments": .array([.string("codex"), .int(1)])]),
            .object([
                "arguments": .array([.string("codex")]),
                "environment": .object(["CODEX_HOME": .int(1)]),
            ]),
            .object([
                "arguments": .array([.string("codex")]),
                "captured_at": .string("now"),
            ]),
        ]
    )
    func surfaceResumeSetRejectsMalformedStructuredLaunchData(
        launchCommand: JSONValue
    ) {
        let context = FakeSurfaceControlCommandContext()
        context.resumeStrings = ControlSurfaceResumeStrings(
            agentSessionEndedMustBeBoolean: "localized boolean validation",
            launchCommandMustBeValid: "localized launch-command validation"
        )
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.resume.set",
            params: [
                "command": .string("codex resume legacy"),
                "launch_command": launchCommand,
            ]
        ))

        #expect(result == .err(
            code: "invalid_params",
            message: "localized launch-command validation",
            data: nil
        ))
        #expect(context.resumeSetInputs == nil)
    }

    @Test func surfaceResumeGetEmitsStructuredRestoreRecord() throws {
        let context = FakeSurfaceControlCommandContext()
        let surfaceID = UUID()
        let command = ControlAgentLaunchCommand(
            launcher: nil,
            executablePath: "/usr/bin/printf",
            arguments: ["/usr/bin/printf", "%s", "quoted ' value"],
            workingDirectory: "/tmp/日本語",
            environment: ["RESTORE_VALUE": "space value"],
            verificationHome: "/tmp/launch-user",
            capturedAt: 21,
            source: "test"
        )
        let binding = ControlSurfaceResumeBinding(
            name: nil,
            kind: "codex",
            command: "codex resume checkpoint",
            cwd: "/tmp/日本語",
            checkpointID: "checkpoint",
            source: "agent-hook",
            environment: ["RESTORE_VALUE": "space value"],
            launchCommand: command,
            permissionMode: "never",
            autoResume: true,
            approvalPolicyRawValue: nil,
            approvalRecordID: nil,
            executionLocationRawValue: "local",
            remoteWorkspaceID: nil,
            remoteSurfaceID: nil,
            remotePTYSessionID: nil,
            updatedAt: 21,
            resumeEvidenceProvenance: "tui"
        )
        context.resumeResolution = .result(ControlSurfaceResumeSnapshot(
            windowID: nil,
            workspaceID: UUID(),
            paneID: nil,
            surfaceID: surfaceID,
            cleared: false,
            binding: binding,
            restoreRecord: ControlSurfaceRestoreRecord(
                modeRawValue: "direct",
                kind: "custom",
                checkpointID: "checkpoint",
                source: "test",
                workingDirectory: "/tmp/日本語",
                environment: ["RESTORE_VALUE": "space value"],
                launchCommand: command,
                preparedArguments: command.arguments,
                preparedArgumentsWorkingDirectory: "/tmp/日本語",
                permissionMode: nil,
                legacyCommand: nil
            )
        ))
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.resume.get",
            params: [:]
        ))
        guard case .ok(.object(let payload)) = result,
              case .object(let resumeBinding)? = payload["resume_binding"],
              case .object(let record)? = payload["restore_record"],
              case .object(let launch)? = record["launch_command"] else {
            Issue.record("expected structured restore record")
            return
        }

        #expect(record["mode"] == .string("direct"))
        #expect(record["working_directory"] == .string("/tmp/日本語"))
        #expect(record["environment"] == .object(["RESTORE_VALUE": .string("space value")]))
        #expect(record["prepared_arguments_working_directory"] == .string("/tmp/日本語"))
        #expect(launch["arguments"] == .array(command.arguments.map(JSONValue.string)))
        #expect(launch["verification_home"] == .string("/tmp/launch-user"))
        #expect(record["legacy_command"] == .null)
        #expect(resumeBinding["resume_evidence_provenance"] == .string("tui"))
    }

    @Test func surfaceResumeGetRejectsPartialRestoreClaim() {
        let context = FakeSurfaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.resume.get",
            params: ["claim_checkpoint_id": .string("checkpoint")]
        ))

        #expect(result == .err(
            code: "invalid_params",
            message: "restore claim must be valid",
            data: nil
        ))
    }

    @Test func surfaceResumeGetForwardsAtomicClaimAndReportsOutcome() throws {
        let context = FakeSurfaceControlCommandContext()
        let surfaceID = UUID()
        context.resumeResolution = .result(ControlSurfaceResumeSnapshot(
            windowID: nil,
            workspaceID: UUID(),
            paneID: nil,
            surfaceID: surfaceID,
            cleared: false,
            binding: nil,
            restoreRecord: nil,
            resumeClaimed: false
        ))
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.resume.get",
            params: [
                "surface_id": .string(surfaceID.uuidString),
                "claim_checkpoint_id": .string("checkpoint"),
                "claim_source": .string("agent-hook"),
                "claim_updated_at": .double(42.5),
            ]
        ))

        #expect(context.resumeGetClaim?.checkpointID == "checkpoint")
        #expect(context.resumeGetClaim?.source == "agent-hook")
        #expect(context.resumeGetClaim?.updatedAt == 42.5)
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected surface resume claim result")
            return
        }
        #expect(payload["resume_claimed"] == .bool(false))
    }

    @Test func surfaceResumeClearForwardsManagedSessionEndProvenance() {
        let context = FakeSurfaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        _ = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.resume.clear",
            params: [
                "agent_session_ended": .bool(true),
                "expected_updated_at": .double(42.5),
            ]
        ))
        #expect(context.resumeClearAgentSessionEnded == true)
        #expect(context.resumeClearExpectedUpdatedAt == 42.5)

        _ = coordinator.handle(ControlRequest(
            id: .int(2),
            method: "surface.resume.clear",
            params: [:]
        ))
        #expect(context.resumeClearAgentSessionEnded == false)
    }

    @Test(
        "surface resume clear rejects malformed session-end provenance",
        arguments: [JSONValue.null, .int(1), .string("true")]
    )
    func surfaceResumeClearRejectsMalformedSessionEndProvenance(value: JSONValue) {
        let context = FakeSurfaceControlCommandContext()
        context.resumeStrings = ControlSurfaceResumeStrings(
            agentSessionEndedMustBeBoolean: "localized boolean validation",
            launchCommandMustBeValid: "localized launch-command validation"
        )
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.resume.clear",
            params: ["agent_session_ended": value]
        ))

        #expect(result == .err(
            code: "invalid_params",
            message: "localized boolean validation",
            data: nil
        ))
        #expect(context.resumeClearAgentSessionEnded == nil)
    }

    @Test func paneCreateDockUnsupportedTypeReturnsInvalidParams() throws {
        let context = FakeSurfaceControlCommandContext()
        context.paneCreateResolution = .dockUnsupportedType(
            typeRawValue: "markdown",
            message: "Dock placement supports only terminal and browser surfaces"
        )
        let coordinator = ControlCommandCoordinator(context: context)
        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "pane.create",
            params: [
                "direction": .string("right"),
                "type": .string("markdown"),
                "placement": .string("dock"),
            ]
        ))

        guard case .err(let code, let message, let data) = result else {
            Issue.record("expected invalid_params error")
            return
        }

        #expect(code == "invalid_params")
        #expect(message == "Dock placement supports only terminal and browser surfaces")
        #expect(data == .object(["type": .string("markdown")]))
    }

    private func makeCoordinator() -> (ControlCommandCoordinator, FakeSurfaceControlCommandContext) {
        let context = FakeSurfaceControlCommandContext()
        return (ControlCommandCoordinator(context: context), context)
    }

    private func request(_ params: [String: JSONValue]) -> ControlRequest {
        ControlRequest(id: .int(1), method: "surface.report_pwd", params: params)
    }

    @Test func reportPWDRejectsConflictingPathAliases() {
        let (coordinator, context) = makeCoordinator()
        let workspaceID = UUID()
        let result = coordinator.handle(request([
            "workspace_id": .string(workspaceID.uuidString),
            "path": .string("/srv/work/bar"),
            "cwd": .string("/srv/work/other"),
        ]))

        #expect(result == .err(code: "invalid_params", message: "Conflicting path parameters", data: nil))
        #expect(context.reportedPWD?.path == nil)
    }

    @Test func reportPWDPreservesExactPathWhitespace() {
        let (coordinator, context) = makeCoordinator()
        let workspaceID = UUID()
        _ = coordinator.handle(request([
            "workspace_id": .string(workspaceID.uuidString),
            "path": .string("/srv/work/bar "),
        ]))

        #expect(context.reportedPWD?.path == "/srv/work/bar ")
    }

    @Test func reportGitBranchForwardsRemoteSurfaceMetadata() {
        let (coordinator, context) = makeCoordinator()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let resolvedSurfaceID = UUID()
        context.reportGitResolution = .recorded(surfaceID: resolvedSurfaceID)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.report_git_branch",
            params: [
                "workspace_id": .string(workspaceID.uuidString),
                "surface_id": .string(surfaceID.uuidString),
                "branch": .string("feature/mosh-parity"),
                "status": .string("unknown"),
            ]
        ))

        #expect(context.reportedGit?.workspaceID == workspaceID)
        #expect(context.reportedGit?.requestedSurfaceID == surfaceID)
        #expect(context.reportedGit?.branch == "feature/mosh-parity")
        #expect(context.reportedGit?.isDirty == nil)
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected Git report success")
            return
        }
        #expect(payload["surface_id"] == .string(resolvedSurfaceID.uuidString))
        #expect(payload["branch"] == .string("feature/mosh-parity"))
        #expect(payload["is_dirty"] == .null)
        #expect(payload["cleared"] == .bool(false))
    }

    @Test func reportGitBranchRejectsInvalidDirtyStatus() {
        let (coordinator, context) = makeCoordinator()
        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.report_git_branch",
            params: [
                "workspace_id": .string(UUID().uuidString),
                "branch": .string("main"),
                "status": .string("maybe"),
            ]
        ))

        #expect(result == .err(
            code: "invalid_params",
            message: "status must be dirty, clean, or unknown",
            data: nil
        ))
        #expect(context.reportedGit == nil)
    }

    @Test func reportShellStateForwardsTerminalLifecycleIdentity() {
        let (coordinator, context) = makeCoordinator()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let terminalLifecycleID = UUID()
        context.reportShellStateResolution = .explicit(
            surfaceID: surfaceID,
            published: true
        )

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.report_shell_state",
            params: [
                "workspace_id": .string(workspaceID.uuidString),
                "surface_id": .string(surfaceID.uuidString),
                "terminal_lifecycle_id": .string(
                    terminalLifecycleID.uuidString
                ),
                "state": .string("prompt"),
            ]
        ))

        #expect(context.reportedShellState?.workspaceID == workspaceID)
        #expect(context.reportedShellState?.requestedSurfaceID == surfaceID)
        #expect(
            context.reportedShellState?.terminalLifecycleID
                == terminalLifecycleID
        )
        #expect(context.reportedShellState?.stateRawValue == "promptIdle")
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected shell-state report success")
            return
        }
        #expect(payload["published"] == .bool(true))
    }

    @Test func reportShellStateRejectsMalformedTerminalLifecycleIdentity() {
        let (coordinator, context) = makeCoordinator()
        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.report_shell_state",
            params: [
                "workspace_id": .string(UUID().uuidString),
                "surface_id": .string(UUID().uuidString),
                "terminal_lifecycle_id": .string("not-a-uuid"),
                "state": .string("prompt"),
            ]
        ))

        #expect(result == .err(
            code: "invalid_params",
            message: "Terminal session is out of date; restart the shell and try again",
            data: nil
        ))
        #expect(context.reportedShellState == nil)
    }

    @Test func reportShellStateReturnsFallbackWhenContextIsUnavailable() {
        let coordinator = ControlCommandCoordinator(context: nil)
        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.report_shell_state",
            params: [
                "workspace_id": .string(UUID().uuidString),
                "terminal_lifecycle_id": .string("not-a-uuid"),
                "state": .string("prompt"),
            ]
        ))

        #expect(result == .err(
            code: "invalid_params",
            message: "Terminal session is out of date; restart the shell and try again",
            data: nil
        ))
    }

    @Test func clearGitBranchResolvesWorkspaceScopedTmuxSurface() {
        let (coordinator, context) = makeCoordinator()
        let workspaceID = UUID()
        let resolvedSurfaceID = UUID()
        context.reportGitResolution = .recorded(surfaceID: resolvedSurfaceID)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.clear_git_branch",
            params: ["workspace_id": .string(workspaceID.uuidString)]
        ))

        #expect(context.clearedGit?.workspaceID == workspaceID)
        #expect(context.clearedGit?.requestedSurfaceID == nil)
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected Git clear success")
            return
        }
        #expect(payload["surface_id"] == .string(resolvedSurfaceID.uuidString))
        #expect(payload["branch"] == .null)
        #expect(payload["cleared"] == .bool(true))
    }
}
