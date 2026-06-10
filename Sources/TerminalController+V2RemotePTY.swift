import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSocketControl
import CmuxSwiftRenderUI
import Carbon.HIToolbox
import CMUXMobileCore
import CMUXWorkstream
import Foundation
import Bonsplit
import WebKit


// MARK: - V2 remote PTY session methods
extension TerminalController {
    private nonisolated func v2RequestedRemotePTYWorkspaceID(params: [String: Any]) -> (
        workspaceId: UUID?,
        error: V2CallResult?
    ) {
        var workspaceId: UUID?
        var invalidWorkspaceID = false
        v2MainSync {
            v2RefreshKnownRefs()
            workspaceId = v2UUID(params, "workspace_id")
            invalidWorkspaceID = v2HasNonNullParam(params, "workspace_id") && workspaceId == nil
        }
        if invalidWorkspaceID {
            return (
                nil,
                .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
            )
        }
        return (workspaceId, nil)
    }

    private nonisolated func v2RequestedRemotePTYSurfaceID(params: [String: Any]) -> (
        surfaceId: UUID?,
        error: V2CallResult?
    ) {
        var surfaceId: UUID?
        var invalidSurfaceID = false
        v2MainSync {
            v2RefreshKnownRefs()
            surfaceId = v2UUID(params, "surface_id")
            invalidSurfaceID = v2HasNonNullParam(params, "surface_id") && surfaceId == nil
        }
        if invalidSurfaceID {
            return (
                nil,
                .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
            )
        }
        return (surfaceId, nil)
    }

    private nonisolated func v2ResolveRemotePTYTarget(
        params: [String: Any],
        requestedWorkspaceId: UUID?,
        preferredSurfaceId: UUID? = nil
    ) -> (target: RemotePTYSocketTarget?, error: V2CallResult?) {
        if v2HasNonNullParam(params, "allow_moved_surface"),
           v2Bool(params, "allow_moved_surface") == nil {
            return (
                nil,
                .err(code: "invalid_params", message: "Missing or invalid allow_moved_surface", data: nil)
            )
        }
        let allowMovedSurface = v2Bool(params, "allow_moved_surface") ?? false
        let requestedSessionID = v2RawString(params, "session_id").flatMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        var resolvedWorkspaceId: UUID?
        var target: RemotePTYSocketTarget?
        var workspaceMismatchData: [String: Any]?

        v2MainSync {
            v2RefreshKnownRefs()
            let fallbackTabManager = v2ResolveTabManager(params: params)
            let fallbackWorkspaceId = requestedWorkspaceId ?? fallbackTabManager?.selectedTabId
            var owner: TabManager?
            var workspace: Workspace?
            if let preferredSurfaceId {
                if let fallbackTabManager,
                   let surfaceWorkspace = fallbackTabManager.tabs.first(where: {
                       $0.panels[preferredSurfaceId] != nil
                           && $0.surfaceIdFromPanelId(preferredSurfaceId) != nil
                   }) {
                    owner = fallbackTabManager
                    workspace = surfaceWorkspace
                } else if let located = AppDelegate.shared?.workspaceContainingPanel(
                    panelId: preferredSurfaceId,
                    preferredWorkspaceId: fallbackWorkspaceId
                ) {
                    owner = located.tabManager
                    workspace = located.workspace
                }
            }
            if workspace == nil,
               let fallbackWorkspaceId,
               let fallbackOwner = AppDelegate.shared?.tabManagerFor(tabId: fallbackWorkspaceId),
               let fallbackWorkspace = fallbackOwner.tabs.first(where: { $0.id == fallbackWorkspaceId }) {
                owner = fallbackOwner
                workspace = fallbackWorkspace
            }
            resolvedWorkspaceId = workspace?.id ?? fallbackWorkspaceId
            guard let owner, let workspace else {
                return
            }
            if let requestedWorkspaceId,
               workspace.id != requestedWorkspaceId {
                let matchedMovedSurface = allowMovedSurface
                    && preferredSurfaceId.map {
                        workspace.remotePTYSessionIDMatches(panelId: $0, sessionID: requestedSessionID)
                    } == true
                guard matchedMovedSurface else {
                    workspaceMismatchData = [
                        "workspace_id": requestedWorkspaceId.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: requestedWorkspaceId),
                        "surface_id": v2OrNull(preferredSurfaceId?.uuidString),
                        "surface_ref": v2Ref(kind: .surface, uuid: preferredSurfaceId),
                        "resolved_workspace_id": workspace.id.uuidString,
                        "resolved_workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                    ]
                    return
                }
            }

            let windowId = v2ResolveWindowId(tabManager: owner)
            target = RemotePTYSocketTarget(
                controller: workspace.remotePTYSessionControllerForSocketCommand(),
                windowId: windowId,
                windowRef: v2Ref(kind: .window, uuid: windowId),
                workspaceId: workspace.id,
                workspaceRef: v2Ref(kind: .workspace, uuid: workspace.id),
                workspaceTitle: workspace.title
            )
        }

        if let workspaceMismatchData {
            return (
                nil,
                .err(
                    code: "invalid_params",
                    message: "surface_id does not belong to workspace_id",
                    data: workspaceMismatchData
                )
            )
        }
        guard let resolvedWorkspaceId else {
            return (
                nil,
                .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
            )
        }
        guard let target else {
            return (
                nil,
                .err(
                    code: "not_found",
                    message: "Workspace not found",
                    data: v2RemotePTYWorkspaceData(workspaceId: resolvedWorkspaceId)
                )
            )
        }
        return (target, nil)
    }

    nonisolated func notifyRemotePTYControllerAvailabilityChanged() {
        remotePTYControllerAvailabilityCondition.lock()
        remotePTYControllerAvailabilityGeneration &+= 1
        remotePTYControllerAvailabilityCondition.broadcast()
        remotePTYControllerAvailabilityCondition.unlock()
    }

    private nonisolated func v2ResolveRemotePTYTargetWaitingForController(
        params: [String: Any],
        requestedWorkspaceId: UUID?,
        preferredSurfaceId: UUID?,
        deadline: Date
    ) -> (target: RemotePTYSocketTarget?, error: V2CallResult?) {
        var observedGeneration: UInt64?

        while true {
            let resolved = v2ResolveRemotePTYTarget(
                params: params,
                requestedWorkspaceId: requestedWorkspaceId,
                preferredSurfaceId: preferredSurfaceId
            )
            if let error = resolved.error {
                return (nil, error)
            }
            guard let target = resolved.target else {
                return resolved
            }
            if target.controller != nil || Date() >= deadline {
                return (target, nil)
            }

            remotePTYControllerAvailabilityCondition.lock()
            let currentGeneration = remotePTYControllerAvailabilityGeneration
            guard let previousGeneration = observedGeneration else {
                observedGeneration = currentGeneration
                remotePTYControllerAvailabilityCondition.unlock()
                continue
            }
            if previousGeneration != currentGeneration {
                observedGeneration = currentGeneration
                remotePTYControllerAvailabilityCondition.unlock()
                continue
            }
            _ = remotePTYControllerAvailabilityCondition.wait(until: deadline)
            observedGeneration = remotePTYControllerAvailabilityGeneration
            remotePTYControllerAvailabilityCondition.unlock()
        }
    }

    private nonisolated func v2RemotePTYWorkspaceData(workspaceId: UUID) -> [String: Any] {
        var workspaceRef: Any = NSNull()
        v2MainSync {
            workspaceRef = v2Ref(kind: .workspace, uuid: workspaceId)
        }
        return [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": workspaceRef,
        ]
    }

    private nonisolated func v2RemotePTYTargetPayload(_ target: RemotePTYSocketTarget) -> [String: Any] {
        [
            "window_id": v2OrNull(target.windowId?.uuidString),
            "window_ref": target.windowRef,
            "workspace_id": target.workspaceId.uuidString,
            "workspace_ref": target.workspaceRef,
            "workspace_title": target.workspaceTitle,
        ]
    }

    nonisolated func v2WorkspaceRemotePTYSessions(params: [String: Any]) -> V2CallResult {
        if v2HasNonNullParam(params, "all_workspaces"), v2Bool(params, "all_workspaces") == nil {
            return .err(code: "invalid_params", message: "Missing or invalid all_workspaces", data: nil)
        }
        let allWorkspaces = v2Bool(params, "all_workspaces") ?? false
        let workspaceSelection = v2RequestedRemotePTYWorkspaceID(params: params)
        if let error = workspaceSelection.error { return error }
        let surfaceSelection = v2RequestedRemotePTYSurfaceID(params: params)
        if let error = surfaceSelection.error { return error }
        let requestedWorkspaceId = workspaceSelection.workspaceId
        if allWorkspaces, requestedWorkspaceId != nil {
            return .err(code: "invalid_params", message: "all_workspaces cannot be combined with workspace_id", data: nil)
        }
        if allWorkspaces {
            var targets: [RemotePTYSocketTarget] = []
            v2MainSync {
                v2RefreshKnownRefs()
                guard let app = AppDelegate.shared else { return }
                for summary in app.listMainWindowSummaries() {
                    guard let owner = app.tabManagerFor(windowId: summary.windowId) else { continue }
                    for workspace in owner.tabs where workspace.isRemoteWorkspace {
                        targets.append(
                            RemotePTYSocketTarget(
                                controller: workspace.remotePTYSessionControllerForSocketCommand(),
                                windowId: summary.windowId,
                                windowRef: v2Ref(kind: .window, uuid: summary.windowId),
                                workspaceId: workspace.id,
                                workspaceRef: v2Ref(kind: .workspace, uuid: workspace.id),
                                workspaceTitle: workspace.title
                            )
                        )
                    }
                }
            }

            var sessions: [[String: Any]] = []
            var errors: [[String: Any]] = []
            for target in targets {
                guard let controller = target.controller else {
                    var payload = v2RemotePTYTargetPayload(target)
                    payload["error"] = "remote connection is not active"
                    errors.append(payload)
                    continue
                }
                do {
                    let workspaceSessions = try controller.listPTYSessions()
                    sessions.append(contentsOf: workspaceSessions.map {
                        v2RemotePTYSessionPayload($0, target: target)
                    })
                } catch {
                    var payload = v2RemotePTYTargetPayload(target)
                    payload["error"] = v2RemotePTYUserFacingErrorMessage(error)
                    errors.append(payload)
                }
            }

            return .ok([
                "all_workspaces": true,
                "workspace_count": targets.count,
                "sessions": sessions,
                "errors": errors,
            ])
        }

        let resolved = v2ResolveRemotePTYTarget(
            params: params,
            requestedWorkspaceId: requestedWorkspaceId,
            preferredSurfaceId: surfaceSelection.surfaceId
        )
        if let error = resolved.error { return error }
        guard let target = resolved.target else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        guard let controller = target.controller else {
            return .err(code: "remote_pty_error", message: "remote connection is not active", data: [
                "workspace_id": target.workspaceId.uuidString,
                "workspace_ref": target.workspaceRef,
            ])
        }

        do {
            let sessions = try controller.listPTYSessions()
            var payload = v2RemotePTYTargetPayload(target)
            payload["sessions"] = sessions.map { v2RemotePTYSessionPayload($0, target: target) }
            return .ok(payload)
        } catch {
            return .err(code: "remote_pty_error", message: v2RemotePTYUserFacingErrorMessage(error), data: [
                "workspace_id": target.workspaceId.uuidString,
                "workspace_ref": target.workspaceRef,
            ])
        }
    }

    private nonisolated func v2RemotePTYSessionPayload(
        _ session: [String: Any],
        target: RemotePTYSocketTarget
    ) -> [String: Any] {
        var payload = session
        payload["window_id"] = v2OrNull(target.windowId?.uuidString)
        payload["window_ref"] = target.windowRef
        payload["workspace_id"] = target.workspaceId.uuidString
        payload["workspace_ref"] = target.workspaceRef
        payload["workspace_title"] = target.workspaceTitle
        return payload
    }

    nonisolated func v2WorkspaceRemotePTYClose(params: [String: Any]) -> V2CallResult {
        let workspaceSelection = v2RequestedRemotePTYWorkspaceID(params: params)
        if let error = workspaceSelection.error { return error }
        guard let sessionID = v2RawString(params, "session_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }
        let surfaceSelection = v2RequestedRemotePTYSurfaceID(params: params)
        if let error = surfaceSelection.error { return error }

        let resolved = v2ResolveRemotePTYTarget(
            params: params,
            requestedWorkspaceId: workspaceSelection.workspaceId,
            preferredSurfaceId: surfaceSelection.surfaceId
        )
        if let error = resolved.error { return error }
        guard let target = resolved.target else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        guard let controller = target.controller else {
            return .err(code: "remote_pty_error", message: "remote connection is not active", data: [
                "workspace_id": target.workspaceId.uuidString,
                "workspace_ref": target.workspaceRef,
                "session_id": sessionID,
            ])
        }

        do {
            try controller.closePTYSession(sessionID: sessionID)
            var payload = v2RemotePTYTargetPayload(target)
            payload["session_id"] = sessionID
            payload["closed"] = true
            return .ok(payload)
        } catch {
            return .err(code: "remote_pty_error", message: v2RemotePTYUserFacingErrorMessage(error), data: [
                "workspace_id": target.workspaceId.uuidString,
                "workspace_ref": target.workspaceRef,
                "session_id": sessionID,
            ])
        }
    }

    nonisolated func v2WorkspaceRemotePTYDetach(params: [String: Any]) -> V2CallResult {
        let workspaceSelection = v2RequestedRemotePTYWorkspaceID(params: params)
        if let error = workspaceSelection.error { return error }
        guard let sessionID = v2RawString(params, "session_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }
        guard let attachmentID = v2RawString(params, "attachment_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !attachmentID.isEmpty else {
            return .err(code: "invalid_params", message: "Missing attachment_id", data: nil)
        }
        guard let attachmentToken = v2RawString(params, "attachment_token")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !attachmentToken.isEmpty else {
            return .err(code: "invalid_params", message: "Missing attachment_token", data: nil)
        }
        let surfaceSelection = v2RequestedRemotePTYSurfaceID(params: params)
        if let error = surfaceSelection.error { return error }

        let resolved = v2ResolveRemotePTYTarget(
            params: params,
            requestedWorkspaceId: workspaceSelection.workspaceId,
            preferredSurfaceId: surfaceSelection.surfaceId
        )
        if let error = resolved.error { return error }
        guard let target = resolved.target else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        guard let controller = target.controller else {
            return .err(code: "remote_pty_error", message: "remote connection is not active", data: [
                "workspace_id": target.workspaceId.uuidString,
                "workspace_ref": target.workspaceRef,
                "session_id": sessionID,
                "attachment_id": attachmentID,
            ])
        }

        do {
            try controller.detachPTYSession(
                sessionID: sessionID,
                attachmentID: attachmentID,
                attachmentToken: attachmentToken
            )
            var payload = v2RemotePTYTargetPayload(target)
            payload["session_id"] = sessionID
            payload["attachment_id"] = attachmentID
            payload["detached"] = true
            return .ok(payload)
        } catch {
            return .err(code: "remote_pty_error", message: v2RemotePTYUserFacingErrorMessage(error), data: [
                "workspace_id": target.workspaceId.uuidString,
                "workspace_ref": target.workspaceRef,
                "session_id": sessionID,
                "attachment_id": attachmentID,
            ])
        }
    }

    nonisolated func v2WorkspaceRemotePTYBridge(params: [String: Any]) -> V2CallResult {
        let workspaceSelection = v2RequestedRemotePTYWorkspaceID(params: params)
        if let error = workspaceSelection.error { return error }
        guard let sessionID = v2RawString(params, "session_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }
        let attachmentID = (v2RawString(params, "attachment_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? UUID().uuidString.lowercased()
        let command = v2RawString(params, "command")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requireExisting = v2Bool(params, "require_existing") ?? false
        let waitForReady = v2Bool(params, "wait_for_ready") ?? false
        let surfaceSelection = v2RequestedRemotePTYSurfaceID(params: params)
        if let error = surfaceSelection.error { return error }
        let preferredSurfaceId = surfaceSelection.surfaceId ?? UUID(uuidString: attachmentID)

        let controllerDeadline = Date().addingTimeInterval(waitForReady ? 90.0 : 8.0)
        let resolved = waitForReady
            ? v2ResolveRemotePTYTargetWaitingForController(
                params: params,
                requestedWorkspaceId: workspaceSelection.workspaceId,
                preferredSurfaceId: preferredSurfaceId,
                deadline: controllerDeadline
            )
            : v2ResolveRemotePTYTarget(
                params: params,
                requestedWorkspaceId: workspaceSelection.workspaceId,
                preferredSurfaceId: preferredSurfaceId
            )
        if let error = resolved.error { return error }
        guard let target = resolved.target else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        guard let controller = target.controller else {
            return .err(code: "remote_pty_error", message: "remote connection is not active", data: [
                "workspace_id": target.workspaceId.uuidString,
                "workspace_ref": target.workspaceRef,
                "session_id": sessionID,
                "attachment_id": attachmentID,
            ])
        }

        do {
            let endpoint = try controller.startPTYBridge(
                sessionID: sessionID,
                attachmentID: attachmentID,
                command: command?.isEmpty == true ? nil : command,
                requireExisting: requireExisting,
                waitForReady: waitForReady,
                timeout: waitForReady ? 90.0 : max(0.1, controllerDeadline.timeIntervalSinceNow)
            )
            var payload = v2RemotePTYTargetPayload(target)
            payload["host"] = endpoint.host
            payload["port"] = endpoint.port
            payload["token"] = endpoint.token
            payload["session_id"] = endpoint.sessionID
            payload["attachment_id"] = endpoint.attachmentID
            return .ok(payload)
        } catch {
            return .err(code: "remote_pty_error", message: v2RemotePTYUserFacingErrorMessage(error), data: [
                "workspace_id": target.workspaceId.uuidString,
                "workspace_ref": target.workspaceRef,
                "session_id": sessionID,
                "attachment_id": attachmentID,
            ])
        }
    }

    nonisolated func v2WorkspaceRemotePTYResize(params: [String: Any]) -> V2CallResult {
        let workspaceSelection = v2RequestedRemotePTYWorkspaceID(params: params)
        if let error = workspaceSelection.error { return error }
        guard let sessionID = v2RawString(params, "session_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }
        guard let attachmentID = v2RawString(params, "attachment_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !attachmentID.isEmpty else {
            return .err(code: "invalid_params", message: "Missing attachment_id", data: nil)
        }
        guard let attachmentToken = v2RawString(params, "attachment_token")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !attachmentToken.isEmpty else {
            return .err(code: "invalid_params", message: "Missing attachment_token", data: nil)
        }
        guard let cols = v2StrictInt(params, "cols"), cols > 0,
              let rows = v2StrictInt(params, "rows"), rows > 0 else {
            return .err(code: "invalid_params", message: "cols and rows must be positive integers", data: nil)
        }
        let surfaceSelection = v2RequestedRemotePTYSurfaceID(params: params)
        if let error = surfaceSelection.error { return error }

        let resolved = v2ResolveRemotePTYTarget(
            params: params,
            requestedWorkspaceId: workspaceSelection.workspaceId,
            preferredSurfaceId: surfaceSelection.surfaceId
        )
        if let error = resolved.error { return error }
        guard let target = resolved.target else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        guard let controller = target.controller else {
            return .err(code: "remote_pty_error", message: "remote connection is not active", data: [
                "workspace_id": target.workspaceId.uuidString,
                "workspace_ref": target.workspaceRef,
                "session_id": sessionID,
                "attachment_id": attachmentID,
            ])
        }

        do {
            try controller.resizePTY(
                sessionID: sessionID,
                attachmentID: attachmentID,
                attachmentToken: attachmentToken,
                cols: cols,
                rows: rows
            )
            var payload = v2RemotePTYTargetPayload(target)
            payload["session_id"] = sessionID
            payload["attachment_id"] = attachmentID
            payload["attachment_token"] = attachmentToken
            payload["cols"] = cols
            payload["rows"] = rows
            payload["resized"] = true
            return .ok(payload)
        } catch {
            return .err(code: "remote_pty_error", message: v2RemotePTYUserFacingErrorMessage(error), data: [
                "workspace_id": target.workspaceId.uuidString,
                "workspace_ref": target.workspaceRef,
                "session_id": sessionID,
                "attachment_id": attachmentID,
            ])
        }
    }

    func v2WorkspaceRemotePTYAttachEnd(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        guard let sessionID = v2RawString(params, "session_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            return .err(code: "invalid_params", message: "Missing session_id", data: nil)
        }

        var result: V2CallResult = .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
            "session_id": sessionID,
            "workspace_found": false,
            "cleared_remote_pty_session": false,
            "untracked_remote_terminal": false,
        ])

        v2MainSync {
            v2RefreshKnownRefs()
            let located = AppDelegate.shared?.workspaceContainingPanel(
                panelId: surfaceId,
                preferredWorkspaceId: workspaceId
            )
            let fallbackOwner = AppDelegate.shared?.tabManagerFor(tabId: workspaceId)
            let fallbackWorkspace = fallbackOwner?.tabs.first(where: { $0.id == workspaceId })
            guard let owner = located?.tabManager ?? fallbackOwner,
                  let workspace = located?.workspace ?? fallbackWorkspace else {
                return
            }
            let outcome = workspace.markRemotePTYAttachEnded(
                surfaceId: surfaceId,
                sessionID: sessionID
            )
            let windowId = v2ResolveWindowId(tabManager: owner)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "session_id": sessionID,
                "workspace_found": true,
                "cleared_remote_pty_session": outcome.clearedRemotePTYSession,
                "untracked_remote_terminal": outcome.untrackedRemoteTerminal,
                "remote": workspace.remoteStatusPayload(),
            ])
        }

        return result
    }

    func v2WorkspaceRemoteTerminalSessionEnd(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        guard let relayPort = v2StrictInt(params, "relay_port"),
              relayPort > 0,
              relayPort <= 65535 else {
            return .err(code: "invalid_params", message: "Missing or invalid relay_port", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
            "relay_port": relayPort,
        ])

        v2MainSync {
            guard let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
                  let workspace = owner.tabs.first(where: { $0.id == workspaceId }) else {
                return
            }
            workspace.markRemoteTerminalSessionEnded(surfaceId: surfaceId, relayPort: relayPort)
            let windowId = v2ResolveWindowId(tabManager: owner)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "relay_port": relayPort,
                "remote": workspace.remoteStatusPayload(),
            ])
        }

        return result
    }

}
