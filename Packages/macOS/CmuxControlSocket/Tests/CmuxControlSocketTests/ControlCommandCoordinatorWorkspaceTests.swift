import Foundation
import CmuxSettings
import os
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator workspace domain")
struct ControlCommandCoordinatorWorkspaceTests {
    private nonisolated static func wait(
        for semaphore: DispatchSemaphore,
        timeout: DispatchTime
    ) -> Bool {
        semaphore.wait(timeout: timeout) == .success
    }

    private func coordinator() -> (ControlCommandCoordinator, FakeWorkspaceControlCommandContext) {
        let context = FakeWorkspaceControlCommandContext()
        return (ControlCommandCoordinator(context: context), context)
    }

    private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    private func summary(id: UUID = UUID(), title: String, customTitle: String?) -> ControlWorkspaceSummary {
        ControlWorkspaceSummary(
            id: id,
            title: title,
            customTitle: customTitle,
            customDescription: nil,
            isPinned: false,
            listeningPorts: [],
            remoteStatus: .object([:]),
            currentDirectory: nil,
            customColor: nil,
            latestConversationMessage: nil,
            latestSubmittedMessage: nil,
            latestSubmittedAt: nil
        )
    }

    @Test func workspaceListExposesCustomTitleState() throws {
        let (coordinator, context) = coordinator()
        let workspaceID = UUID()
        context.listResolution = .resolved(
            windowID: nil,
            workspaces: [summary(id: workspaceID, title: "Manual name", customTitle: "Manual name")],
            selectedIndex: 0
        )

        guard case .ok(.object(let payload)) = coordinator.handle(request("workspace.list")),
              case .array(let rows) = payload["workspaces"],
              case .object(let row) = rows.first else {
            Issue.record("unexpected workspace.list shape")
            return
        }

        #expect(row["id"] == .string(workspaceID.uuidString))
        #expect(row["title"] == .string("Manual name"))
        #expect(row["custom_title"] == .string("Manual name"))
        #expect(row["has_custom_title"] == .bool(true))
    }

    @Test func asyncFeedJumpUsesTheAsyncResolutionSeam() async throws {
        let context = FakeWorkspaceControlCommandContext(feedJumpMatch: true)
        let result = await ControlCommandCoordinator().handleSocketWorkerFeedAsync(
            request("feed.jump", ["workstream_id": .string("known")]),
            context: context
        )

        guard case .ok(.object(let payload)) = result,
              payload["workstream_id"] == .string("known"),
              payload["matched"] == .bool(true) else {
            Issue.record("unexpected async feed.jump result")
            return
        }
    }

    @Test func syncFeedJumpUsesTheSynchronousResolutionSeam() throws {
        let context = FakeWorkspaceControlCommandContext(feedJumpMatch: true)
        let result = ControlCommandCoordinator().handleSocketWorkerFeed(
            request("feed.jump", ["workstream_id": .string("known")]),
            context: context
        )

        guard case .ok(.object(let payload)) = result,
              payload["workstream_id"] == .string("known"),
              payload["matched"] == .bool(true) else {
            Issue.record("unexpected sync feed.jump result")
            return
        }
    }

    @Test func workspaceCurrentExposesMissingCustomTitleState() throws {
        let (coordinator, context) = coordinator()
        let workspaceID = UUID()
        context.currentResolution = .resolved(
            windowID: nil,
            workspaceID: workspaceID,
            index: 0,
            summary: summary(id: workspaceID, title: "Terminal", customTitle: nil)
        )

        guard case .ok(.object(let payload)) = coordinator.handle(request("workspace.current")),
              case .object(let workspace) = payload["workspace"] else {
            Issue.record("unexpected workspace.current shape")
            return
        }

        #expect(workspace["title"] == .string("Terminal"))
        #expect(workspace["custom_title"] == .null)
        #expect(workspace["has_custom_title"] == .bool(false))
    }

    @Test func workspaceCloseReportsKnownTeardownFailureDistinctly() throws {
        let (coordinator, context) = coordinator()
        let workspaceID = UUID()
        let windowID = UUID()
        context.closeResolution = .closeFailed(windowID: windowID)

        guard case .err(let code, let message, .object(let data)) = coordinator.handle(request(
            "workspace.close",
            ["workspace_id": .string(workspaceID.uuidString)]
        )) else {
            Issue.record("unexpected workspace.close result")
            return
        }

        #expect(code == "internal_error")
        #expect(message == "close failed")
        #expect(data["window_id"] == .string(windowID.uuidString))
        #expect(data["workspace_id"] == .string(workspaceID.uuidString))
    }

    @Test func workspaceGroupAddForwardsPlacementAndReference() throws {
        let (coordinator, context) = coordinator()
        let groupID = UUID()
        let workspaceID = UUID()
        let referenceWorkspaceID = UUID()
        context.addWorkspaceToGroupResolution = .added

        guard case .ok(.object(let payload)) = coordinator.handle(request("workspace.group.add", [
            "group_id": .string(groupID.uuidString),
            "workspace_id": .string(workspaceID.uuidString),
            "placement": .string("after-current"),
            "reference_workspace_id": .string(referenceWorkspaceID.uuidString),
        ])) else {
            Issue.record("unexpected workspace.group.add result")
            return
        }

        #expect(payload["group_id"] == .string(groupID.uuidString))
        #expect(payload["workspace_id"] == .string(workspaceID.uuidString))
        #expect(context.addWorkspaceToGroupCall?.groupID == groupID)
        #expect(context.addWorkspaceToGroupCall?.workspaceID == workspaceID)
        #expect(context.addWorkspaceToGroupCall?.placement == .afterCurrent)
        #expect(context.addWorkspaceToGroupCall?.referenceWorkspaceID == referenceWorkspaceID)
    }

    @Test func workspaceGroupAddAcceptsNullReferenceWorkspaceID() throws {
        let (coordinator, context) = coordinator()
        let groupID = UUID()
        let workspaceID = UUID()
        context.addWorkspaceToGroupResolution = .added

        guard case .ok(.object(let payload)) = coordinator.handle(request("workspace.group.add", [
            "group_id": .string(groupID.uuidString),
            "workspace_id": .string(workspaceID.uuidString),
            "placement": .string("top"),
            "reference_workspace_id": .null,
        ])) else {
            Issue.record("unexpected workspace.group.add result")
            return
        }

        #expect(payload["group_id"] == .string(groupID.uuidString))
        #expect(payload["workspace_id"] == .string(workspaceID.uuidString))
        #expect(context.addWorkspaceToGroupCall?.groupID == groupID)
        #expect(context.addWorkspaceToGroupCall?.workspaceID == workspaceID)
        #expect(context.addWorkspaceToGroupCall?.placement == .top)
        #expect(context.addWorkspaceToGroupCall?.referenceWorkspaceID == nil)
    }

    @Test func workspaceGroupAddRejectsReferenceOutsideTargetGroup() throws {
        let (coordinator, context) = coordinator()
        let groupID = UUID()
        let workspaceID = UUID()
        let referenceWorkspaceID = UUID()
        context.addWorkspaceToGroupResolution = .invalidReferenceWorkspace

        guard case .err(let code, let message, let data) = coordinator.handle(request("workspace.group.add", [
            "group_id": .string(groupID.uuidString),
            "workspace_id": .string(workspaceID.uuidString),
            "placement": .string("afterCurrent"),
            "reference_workspace_id": .string(referenceWorkspaceID.uuidString),
        ])) else {
            Issue.record("unexpected workspace.group.add result")
            return
        }

        #expect(code == "invalid_params")
        #expect(message == "invalid reference workspace")
        #expect(data == .object(["reference_workspace_id": .string(referenceWorkspaceID.uuidString)]))
        #expect(context.addWorkspaceToGroupCall?.referenceWorkspaceID == referenceWorkspaceID)
    }

    @Test func workspaceGroupAddRejectsInvalidPlacement() throws {
        let (coordinator, context) = coordinator()
        let groupID = UUID()
        let workspaceID = UUID()

        guard case .err(let code, let message, _) = coordinator.handle(request("workspace.group.add", [
            "group_id": .string(groupID.uuidString),
            "workspace_id": .string(workspaceID.uuidString),
            "placement": .string("middle"),
        ])) else {
            Issue.record("unexpected workspace.group.add result")
            return
        }

        #expect(code == "invalid_params")
        #expect(message == "Invalid placement")
        #expect(context.addWorkspaceToGroupCall == nil)
    }

    @Test func terminalSessionEndForwardsLifecycleRetirementIntent() throws {
        let (coordinator, context) = coordinator()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let sessionID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let lifecycleID = "11111111-2222-3333-4444-555555555555"
        context.terminalSessionEndResolution = .resolved(
            windowID: nil,
            workspaceID: workspaceID,
            remoteStatus: .object([:])
        )

        guard case .ok = coordinator.handle(request("workspace.remote.terminal_session_end", [
            "workspace_id": .string(workspaceID.uuidString),
            "surface_id": .string(surfaceID.uuidString),
            "session_id": .string(sessionID),
            "lifecycle_id": .string(lifecycleID),
            "lifecycle_only": .bool(true),
        ])) else {
            Issue.record("unexpected terminal_session_end result")
            return
        }

        #expect(context.terminalSessionEndCall?.workspaceID == workspaceID)
        #expect(context.terminalSessionEndCall?.surfaceID == surfaceID)
        #expect(context.terminalSessionEndCall?.relayPort == nil)
        #expect(context.terminalSessionEndCall?.sessionID == sessionID)
        #expect(context.terminalSessionEndCall?.lifecycleID == lifecycleID)
        #expect(context.terminalSessionEndCall?.lifecycleOnly == true)
    }

    @Test func terminalSessionLaunchingForwardsAttemptGeneration() throws {
        let (coordinator, context) = coordinator()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let terminalLifecycleID = UUID()
        let attemptID = UUID()
        context.terminalSessionConnectedResolution = .resolved(
            windowID: nil,
            workspaceID: workspaceID,
            remoteStatus: .object(["connected": .bool(false)])
        )

        guard case .ok = coordinator.handleSocketWorkerV2(
            request("workspace.remote.terminal_session_launching", [
                "workspace_id": .string(workspaceID.uuidString),
                "surface_id": .string(surfaceID.uuidString),
                "terminal_lifecycle_id": .string(terminalLifecycleID.uuidString),
                "attempt_id": .string(attemptID.uuidString),
            ]),
            context: context
        ) else {
            Issue.record("unexpected terminal_session_launching result")
            return
        }

        #expect(context.terminalSessionLaunchingCall?.workspaceID == workspaceID)
        #expect(context.terminalSessionLaunchingCall?.surfaceID == surfaceID)
        #expect(
            context.terminalSessionLaunchingCall?.terminalLifecycleID ==
                terminalLifecycleID
        )
        #expect(context.terminalSessionLaunchingCall?.attemptID == attemptID)
    }

    @Test func terminalSessionConnectedForwardsAuthoritativeTerminalLiveness() throws {
        let (coordinator, context) = coordinator()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let terminalLifecycleID = UUID()
        let attemptID = UUID()
        context.terminalSessionConnectedResolution = .resolved(
            windowID: nil,
            workspaceID: workspaceID,
            remoteStatus: .object(["connected": .bool(true)])
        )

        guard case .ok = coordinator.handleSocketWorkerV2(
            request("workspace.remote.terminal_session_connected", [
            "workspace_id": .string(workspaceID.uuidString),
            "surface_id": .string(surfaceID.uuidString),
            "relay_port": .int(64007),
            "terminal_lifecycle_id": .string(terminalLifecycleID.uuidString),
            "attempt_id": .string(attemptID.uuidString),
            ]),
            context: context
        ) else {
            Issue.record("unexpected terminal_session_connected result")
            return
        }

        #expect(context.terminalSessionConnectedCall?.workspaceID == workspaceID)
        #expect(context.terminalSessionConnectedCall?.surfaceID == surfaceID)
        #expect(context.terminalSessionConnectedCall?.attemptID == attemptID)
        #expect(
            context.terminalSessionConnectedCall?.authority ==
                .relayPort(64007, terminalLifecycleID: terminalLifecycleID)
        )
    }

    @Test func terminalSessionConnectedRejectsMissingAttemptGeneration() throws {
        let (coordinator, context) = coordinator()
        context.terminalSessionConnectedResolution = .resolved(
            windowID: nil,
            workspaceID: UUID(),
            remoteStatus: .object(["connected": .bool(true)])
        )

        guard case .err(let code, _, _) = coordinator.handleSocketWorkerV2(
            request("workspace.remote.terminal_session_connected", [
                "workspace_id": .string(UUID().uuidString),
                "surface_id": .string(UUID().uuidString),
                "relay_port": .int(64_007),
                "terminal_lifecycle_id": .string(UUID().uuidString),
            ]),
            context: context
        ) else {
            Issue.record("terminal readiness without an attempt generation was accepted")
            return
        }

        #expect(code == "invalid_params")
        #expect(context.terminalSessionConnectedCall == nil)
    }

    @Test func persistentTerminalSessionConnectedForwardsLifecycleAuthority() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let sessionID = "ssh-session"
        let lifecycleID = UUID().uuidString.lowercased()
        let terminalLifecycleID = UUID()
        let attemptID = UUID()
        let context = FakeWorkspaceControlCommandContext(
            currentRemotePTYLifecycleOwner: ControlRemotePTYLifecycleOwner(
                transportKey: "persistent-transport",
                attachmentID: surfaceID.uuidString.lowercased(),
                commitLease: FixedRemotePTYLifecycleCommitLease(isCurrent: true)
            )
        )
        let coordinator = ControlCommandCoordinator(context: context)
        context.terminalSessionConnectedResolution = .resolved(
            windowID: nil,
            workspaceID: workspaceID,
            remoteStatus: .object(["connected": .bool(true)])
        )

        guard case .ok = coordinator.handleSocketWorkerV2(
            request("workspace.remote.terminal_session_connected", [
                "workspace_id": .string(workspaceID.uuidString),
                "surface_id": .string(surfaceID.uuidString),
                "session_id": .string(sessionID),
                "lifecycle_id": .string(lifecycleID),
                "terminal_lifecycle_id": .string(terminalLifecycleID.uuidString),
                "attempt_id": .string(attemptID.uuidString),
            ]),
            context: context
        ) else {
            Issue.record("unexpected persistent terminal_session_connected result")
            return
        }

        #expect(
            context.terminalSessionConnectedCall?.authority ==
                .persistentTransport(
                    "persistent-transport",
                    terminalLifecycleID: terminalLifecycleID
                )
        )
        #expect(context.terminalSessionConnectedCall?.attemptID == attemptID)
    }

    @Test func persistentTerminalSessionConnectedRejectsAnotherSurfaceOwner() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let context = FakeWorkspaceControlCommandContext(
            currentRemotePTYLifecycleOwner: ControlRemotePTYLifecycleOwner(
                transportKey: "persistent-transport",
                attachmentID: UUID().uuidString,
                commitLease: FixedRemotePTYLifecycleCommitLease(isCurrent: true)
            )
        )
        let coordinator = ControlCommandCoordinator(context: context)

        guard case .err(let code, _, _) = coordinator.handleSocketWorkerV2(
            request("workspace.remote.terminal_session_connected", [
                "workspace_id": .string(workspaceID.uuidString),
                "surface_id": .string(surfaceID.uuidString),
                "session_id": .string("ssh-session"),
                "lifecycle_id": .string("current-lifecycle"),
                "terminal_lifecycle_id": .string(UUID().uuidString),
                "attempt_id": .string(UUID().uuidString),
            ]),
            context: context
        ) else {
            Issue.record("another surface's lifecycle owner was accepted")
            return
        }

        #expect(code == "not_found")
        #expect(context.terminalSessionConnectedCall == nil)
    }

    @Test func persistentTerminalSessionConnectedRejectsLifecycleRetiredBeforeMainCommit() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let sessionID = "ssh-session"
        let lifecycleID = UUID().uuidString.lowercased()
        let terminalLifecycleID = UUID()
        let owner = ControlRemotePTYLifecycleOwner(
            transportKey: "persistent-transport",
            attachmentID: surfaceID.uuidString,
            commitLease: FixedRemotePTYLifecycleCommitLease(isCurrent: false)
        )
        let ownerReadCount = OSAllocatedUnfairLock(initialState: 0)
        let context = FakeWorkspaceControlCommandContext(
            currentRemotePTYLifecycleOwnerProvider: {
                ownerReadCount.withLock { count in
                    count += 1
                    return owner
                }
            }
        )
        let coordinator = ControlCommandCoordinator(context: context)
        context.terminalSessionConnectedResolution = .resolved(
            windowID: nil,
            workspaceID: workspaceID,
            remoteStatus: .object(["connected": .bool(true)])
        )

        guard case .err(let code, _, _) = coordinator.handleSocketWorkerV2(
            request("workspace.remote.terminal_session_connected", [
                "workspace_id": .string(workspaceID.uuidString),
                "surface_id": .string(surfaceID.uuidString),
                "session_id": .string(sessionID),
                "lifecycle_id": .string(lifecycleID),
                "terminal_lifecycle_id": .string(terminalLifecycleID.uuidString),
                "attempt_id": .string(UUID().uuidString),
            ]),
            context: context
        ) else {
            Issue.record("retired persistent lifecycle was accepted")
            return
        }

        #expect(code == "not_found")
        #expect(context.terminalSessionConnectedCall == nil)
        #expect(ownerReadCount.withLock { $0 } == 1)
    }

    @Test
    nonisolated func persistentReadinessCoalescesWhileFirstMainHopIsBlocked() async throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let terminalLifecycleID = UUID()
        let attemptID = UUID()
        let firstMainHopEntered = DispatchSemaphore(value: 0)
        let releaseMainHop = DispatchSemaphore(value: 0)
        let firstFinished = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        let firstResult = SimulatorResultBox()
        let secondResult = SimulatorResultBox()
        let mainHopCount = OSAllocatedUnfairLock(initialState: 0)
        let setup = await MainActor.run {
            let context = FakeWorkspaceControlCommandContext(
                currentRemotePTYLifecycleOwner: ControlRemotePTYLifecycleOwner(
                    transportKey: "persistent-transport",
                    attachmentID: surfaceID.uuidString,
                    commitLease: FixedRemotePTYLifecycleCommitLease(isCurrent: true)
                ),
                beforeMainResolution: {
                    mainHopCount.withLock { $0 += 1 }
                    firstMainHopEntered.signal()
                    _ = releaseMainHop.wait(timeout: .now() + 2)
                }
            )
            context.terminalSessionConnectedResolution = .resolved(
                windowID: nil,
                workspaceID: workspaceID,
                remoteStatus: .object(["connected": .bool(true)])
            )
            return (ControlCommandCoordinator(context: context), context)
        }
        let request = ControlRequest(
            id: .int(1),
            method: "workspace.remote.terminal_session_connected",
            params: [
                "workspace_id": .string(workspaceID.uuidString),
                "surface_id": .string(surfaceID.uuidString),
                "session_id": .string("ssh-session"),
                "lifecycle_id": .string("lifecycle-generation"),
                "terminal_lifecycle_id": .string(terminalLifecycleID.uuidString),
                "attempt_id": .string(attemptID.uuidString),
            ]
        )

        DispatchQueue.global(qos: .userInitiated).async {
            if let result = setup.0.handleSocketWorkerV2(request, context: setup.1) {
                firstResult.set(result)
            }
            firstFinished.signal()
        }
        let didEnterFirstMainHop = await Task.detached {
            Self.wait(for: firstMainHopEntered, timeout: .now() + 1)
        }.value
        #expect(didEnterFirstMainHop)

        DispatchQueue.global(qos: .userInitiated).async {
            if let result = setup.0.handleSocketWorkerV2(request, context: setup.1) {
                secondResult.set(result)
            }
            secondFinished.signal()
        }
        let duplicateCompletedBeforeMainHop = await Task.detached {
            Self.wait(for: secondFinished, timeout: .now() + 0.25)
        }.value

        releaseMainHop.signal()
        releaseMainHop.signal()
        let didFinishFirst = await Task.detached {
            Self.wait(for: firstFinished, timeout: .now() + 1)
        }.value
        #expect(didFinishFirst)
        if !duplicateCompletedBeforeMainHop {
            let didFinishSecond = await Task.detached {
                Self.wait(for: secondFinished, timeout: .now() + 1)
            }.value
            #expect(didFinishSecond)
        }

        #expect(
            duplicateCompletedBeforeMainHop,
            "A duplicate readiness report must not queue another main-actor mutation"
        )
        guard case .err(let code, _, _) = secondResult.get() else {
            Issue.record("in-flight duplicate readiness was not rejected")
            return
        }
        #expect(code == "busy")
        guard case .ok = firstResult.get() else {
            Issue.record("the admitted readiness report did not complete")
            return
        }
        guard case .ok = setup.0.handleSocketWorkerV2(request, context: setup.1) else {
            Issue.record("completed readiness was not acknowledged idempotently")
            return
        }
        #expect(
            mainHopCount.withLock { $0 } == 1,
            "Completed readiness must not re-enter the main actor"
        )
    }

    @Test(arguments: [
        ["relay_port": JSONValue.int(64007)],
        ["relay_port": JSONValue.int(64007), "terminal_lifecycle_id": .string("invalid")],
        ["relay_port": JSONValue.int(64007), "terminal_lifecycle_id": .string(UUID().uuidString), "session_id": .string("session"), "lifecycle_id": .string("lifecycle")],
        ["session_id": JSONValue.string("session"), "terminal_lifecycle_id": .string(UUID().uuidString)],
        ["lifecycle_id": JSONValue.string("lifecycle"), "terminal_lifecycle_id": .string(UUID().uuidString)],
        ["terminal_lifecycle_id": JSONValue.string(UUID().uuidString)],
    ])
    func terminalSessionConnectedRejectsAmbiguousAuthority(
        authority: [String: JSONValue]
    ) throws {
        let (coordinator, context) = coordinator()
        var params = authority
        params["workspace_id"] = .string(UUID().uuidString)
        params["surface_id"] = .string(UUID().uuidString)
        params["attempt_id"] = .string(UUID().uuidString)

        guard case .err(let code, _, _) = coordinator.handleSocketWorkerV2(
            request("workspace.remote.terminal_session_connected", params),
            context: context
        ) else {
            Issue.record("ambiguous terminal authority was accepted")
            return
        }

        #expect(code == "invalid_params")
        #expect(context.terminalSessionConnectedCall == nil)
    }

    @Test func lifecycleOnlySessionEndRejectsMissingGeneration() throws {
        let (coordinator, context) = coordinator()
        guard case .err(let code, _, _) = coordinator.handle(request(
            "workspace.remote.terminal_session_end",
            [
                "workspace_id": .string(UUID().uuidString),
                "surface_id": .string(UUID().uuidString),
                "lifecycle_only": .bool(true),
            ]
        )) else {
            Issue.record("incomplete lifecycle-only request was accepted")
            return
        }

        #expect(code == "invalid_params")
        #expect(context.terminalSessionEndCall == nil)
    }

    @Test func relaySessionEndRejectsMissingTerminalGeneration() throws {
        let (coordinator, context) = coordinator()
        context.terminalSessionEndResolution = .resolved(
            windowID: nil,
            workspaceID: UUID(),
            remoteStatus: .object([:])
        )

        guard case .err(let code, _, _) = coordinator.handle(request(
            "workspace.remote.terminal_session_end",
            [
                "workspace_id": .string(UUID().uuidString),
                "surface_id": .string(UUID().uuidString),
                "relay_port": .int(64_007),
            ]
        )) else {
            Issue.record("relay end without a terminal generation was accepted")
            return
        }

        #expect(code == "invalid_params")
        #expect(context.terminalSessionEndCall == nil)
    }

    @Test func relaySessionEndForwardsTerminalGeneration() throws {
        let (coordinator, context) = coordinator()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let terminalLifecycleID = UUID()
        context.terminalSessionEndResolution = .resolved(
            windowID: nil,
            workspaceID: workspaceID,
            remoteStatus: .object([:])
        )

        guard case .ok = coordinator.handle(request(
            "workspace.remote.terminal_session_end",
            [
                "workspace_id": .string(workspaceID.uuidString),
                "surface_id": .string(surfaceID.uuidString),
                "relay_port": .int(64_007),
                "terminal_lifecycle_id": .string(terminalLifecycleID.uuidString),
            ]
        )) else {
            Issue.record("relay end with a terminal generation was rejected")
            return
        }

        #expect(context.terminalSessionEndCall?.workspaceID == workspaceID)
        #expect(context.terminalSessionEndCall?.surfaceID == surfaceID)
        #expect(context.terminalSessionEndCall?.relayPort == 64_007)
        #expect(
            context.terminalSessionEndCall?.terminalLifecycleID ==
                terminalLifecycleID
        )
        #expect(context.terminalSessionEndCall?.lifecycleOnly == false)
    }

    @Test func foregroundAuthenticationForwardsResolvedControlPath() {
        let (coordinator, context) = coordinator()
        let workspaceID = UUID()
        context.foregroundAuthResolution = .unavailable(
            workspaceID: workspaceID,
            message: "localized ownership unavailable"
        )

        guard case .err(let code, let message, _) = coordinator.handle(request(
            "workspace.remote.foreground_auth_ready",
            [
                "workspace_id": .string(workspaceID.uuidString),
                "foreground_auth_token": .string(" auth-token "),
                "control_path": .string(
                    " /tmp/cmux-ssh-501-0123456789abcdef "
                ),
            ]
        )) else {
            Issue.record("unexpected foreground-auth result")
            return
        }

        #expect(code == "unavailable")
        #expect(message == "localized ownership unavailable")
        #expect(context.foregroundAuthCall?.workspaceID == workspaceID)
        #expect(context.foregroundAuthCall?.token == "auth-token")
        #expect(
            context.foregroundAuthCall?.controlPath ==
                "/tmp/cmux-ssh-501-0123456789abcdef"
        )
    }

    @Test func foregroundAuthenticationRequiresNonemptyToken() {
        let (coordinator, context) = coordinator()
        let workspaceID = UUID()
        let requests: [[String: JSONValue]] = [
            ["workspace_id": .string(workspaceID.uuidString)],
            [
                "workspace_id": .string(workspaceID.uuidString),
                "foreground_auth_token": .string(" \n "),
            ],
        ]

        for params in requests {
            guard case .err(let code, let message, _) =
                coordinator.handle(request(
                    "workspace.remote.foreground_auth_ready",
                    params
                )) else {
                Issue.record("missing foreground-auth token was accepted")
                continue
            }
            #expect(code == "invalid_params")
            #expect(message == "Missing foreground_auth_token")
        }
        #expect(context.foregroundAuthCall == nil)
    }

    @Test func foregroundAuthenticationNormalizesBlankControlPath() {
        let (coordinator, context) = coordinator()
        let workspaceID = UUID()
        context.foregroundAuthResolution = .unavailable(
            workspaceID: workspaceID,
            message: "localized ownership unavailable"
        )

        _ = coordinator.handle(request(
            "workspace.remote.foreground_auth_ready",
            [
                "workspace_id": .string(workspaceID.uuidString),
                "foreground_auth_token": .string("auth-token"),
                "control_path": .string(" \n "),
            ]
        ))

        #expect(context.foregroundAuthCall?.token == "auth-token")
        #expect(context.foregroundAuthCall?.controlPath == nil)
    }
}
