import CMUXMobileCore
import CmuxMobilePairedMac
internal import CmuxMobileDiagnostics
internal import CmuxMobileRPC
public import CmuxMobileShellModel
internal import Foundation
internal import OSLog

private let mobileShellLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

// MARK: - Workspace actions (rename / pin / read-state / close / move / groups)
//
// The mobile-gated workspace mutations re-sync the owning Mac's authoritative
// workspace list after the request returns. That covers success, rejected
// actions (e.g. attempting to close the last workspace), and dropped push events
// without re-fetching unrelated saved Macs for a single owner-local edit.
extension MobileShellComposite {

    /// Rename a workspace on the Mac.
    ///
    /// Sends the mutation to the Mac, then re-syncs from the authoritative
    /// workspace list. The refresh also runs after rejected/no-op actions so iOS
    /// can snap back to the Mac's real state.
    /// - Parameters:
    ///   - id: The workspace to rename.
    ///   - title: The new title. Whitespace-only titles are ignored.
    /// - Returns: `success` when the Mac accepted the rename, otherwise the
    ///   failure the UI should surface.
    @discardableResult
    public func renameWorkspace(
        id: MobileWorkspacePreview.ID,
        title: String,
        refreshAfterMutation: Bool = true
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        guard workspaceActionCapabilities(for: id).supportsWorkspaceActions else {
            recordAppEvent(
                .workspaceMutationUnavailable,
                correlationID: id.rawValue,
                failure: .policyUnavailable
            )
            return .failure(.unsupported(hostDisplayName: workspaceHostDisplayName(for: id)))
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success(()) }
        var params = workspaceMutationParams(id: id)
        params["action"] = "rename"
        params["title"] = trimmed
        return await sendWorkspaceMutation(
            method: "workspace.action",
            params: params,
            id: id,
            actionName: "rename",
            refreshAfterMutation: refreshAfterMutation
        )
    }

    /// Pin or unpin a workspace on the Mac.
    ///
    /// Sends the mutation to the Mac, then re-syncs from the authoritative
    /// workspace list. The refresh also runs after rejected/no-op actions so iOS
    /// can snap back to the Mac's real state.
    /// - Parameters:
    ///   - id: The workspace to pin or unpin.
    ///   - pinned: `true` to pin, `false` to unpin.
    /// - Returns: `success` when the Mac accepted the request, otherwise the
    ///   failure the UI should surface.
    @discardableResult
    public func setWorkspacePinned(
        id: MobileWorkspacePreview.ID,
        _ pinned: Bool,
        refreshAfterMutation: Bool = true
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        guard workspaceActionCapabilities(for: id).supportsWorkspaceActions else {
            recordAppEvent(
                .workspaceMutationUnavailable,
                correlationID: id.rawValue,
                failure: .policyUnavailable
            )
            return .failure(.unsupported(hostDisplayName: workspaceHostDisplayName(for: id)))
        }
        var params = workspaceMutationParams(id: id)
        params["action"] = pinned ? "pin" : "unpin"
        return await sendWorkspaceMutation(
            method: "workspace.action",
            params: params,
            id: id,
            actionName: pinned ? "pin" : "unpin",
            refreshAfterMutation: refreshAfterMutation
        )
    }

    /// Set or clear a workspace's custom description on the Mac.
    /// - Parameters:
    ///   - id: The workspace to update.
    ///   - description: The description, or `nil`/whitespace to clear it.
    /// - Returns: `success` when the Mac accepted the request, otherwise the
    ///   failure the UI should surface.
    @discardableResult
    public func setWorkspaceDescription(
        id: MobileWorkspacePreview.ID,
        _ description: String?,
        refreshAfterMutation: Bool = true
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        guard workspaceActionCapabilities(for: id).supportsWorkspaceMetadata else {
            recordAppEvent(
                .workspaceMutationUnavailable,
                correlationID: id.rawValue,
                failure: .policyUnavailable
            )
            return .failure(.unsupported(hostDisplayName: workspaceHostDisplayName(for: id)))
        }
        let normalized = MobileWorkspaceMetadataLimits.normalizedCustomDescription(description)
        let hasDescription = normalized != nil
        var params = workspaceMutationParams(id: id)
        if let normalized, hasDescription {
            params["action"] = "set_description"
            params["description"] = normalized
        } else {
            params["action"] = "clear_description"
        }
        return await sendWorkspaceMutation(
            method: "workspace.action",
            params: params,
            id: id,
            actionName: hasDescription ? "set_description" : "clear_description",
            refreshAfterMutation: refreshAfterMutation
        )
    }

    /// Set or clear a workspace's custom color on the Mac.
    /// - Parameters:
    ///   - id: The workspace to update.
    ///   - colorHex: A `#RRGGBB` color, or `nil`/whitespace to clear it.
    /// - Returns: `success` when the Mac accepted the request, otherwise the
    ///   failure the UI should surface.
    @discardableResult
    public func setWorkspaceColor(
        id: MobileWorkspacePreview.ID,
        _ colorHex: String?,
        refreshAfterMutation: Bool = true
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        guard workspaceActionCapabilities(for: id).supportsWorkspaceMetadata else {
            recordAppEvent(
                .workspaceMutationUnavailable,
                correlationID: id.rawValue,
                failure: .policyUnavailable
            )
            return .failure(.unsupported(hostDisplayName: workspaceHostDisplayName(for: id)))
        }
        let normalized = colorHex?.trimmingCharacters(in: .whitespacesAndNewlines)
        var params = workspaceMutationParams(id: id)
        if let normalized, !normalized.isEmpty {
            params["action"] = "set_color"
            params["color"] = normalized
        } else {
            params["action"] = "clear_color"
        }
        return await sendWorkspaceMutation(
            method: "workspace.action",
            params: params,
            id: id,
            actionName: normalized?.isEmpty == false ? "set_color" : "clear_color",
            refreshAfterMutation: refreshAfterMutation
        )
    }

    /// Mark a workspace read or unread on the Mac, then re-sync the authoritative
    /// list so the swipe label flips even if the push event is delayed.
    /// - Parameters:
    ///   - id: The workspace to mark.
    ///   - unread: `true` to mark unread, `false` to mark read.
    /// - Returns: `success` when the Mac accepted the request, otherwise the
    ///   failure the UI should surface.
    @discardableResult
    public func setWorkspaceUnread(
        id: MobileWorkspacePreview.ID,
        _ unread: Bool
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        guard workspaceActionCapabilities(for: id).supportsReadStateActions else {
            recordAppEvent(
                .workspaceMutationUnavailable,
                correlationID: id.rawValue,
                failure: .policyUnavailable
            )
            return .failure(.unsupported(hostDisplayName: workspaceHostDisplayName(for: id)))
        }
        var params = workspaceMutationParams(id: id)
        params["action"] = unread ? "mark_unread" : "mark_read"
        return await sendWorkspaceMutation(
            method: "workspace.action",
            params: params,
            id: id,
            actionName: unread ? "mark_unread" : "mark_read"
        )
    }

    /// Close a workspace on the Mac.
    ///
    /// Sends the mutation to the Mac, then re-syncs from the authoritative
    /// workspace list. If the Mac rejects the close, for example because it is
    /// the last workspace, the refresh restores the row state on iOS.
    /// - Parameter id: The workspace to close.
    /// - Returns: `success` when the Mac accepted the request, otherwise the
    ///   failure the UI should surface.
    @discardableResult
    public func closeWorkspace(
        id: MobileWorkspacePreview.ID
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        let terminalIDs = workspaces.first(where: { $0.id == id })?.terminals.map(\.id.rawValue) ?? []
        for terminalID in terminalIDs {
            recordAppEvent(.surfaceCloseStarted, correlationID: terminalID)
        }
        guard workspaceActionCapabilities(for: id).supportsCloseActions else {
            recordAppEvent(
                .workspaceMutationUnavailable,
                correlationID: id.rawValue,
                failure: .policyUnavailable
            )
            for terminalID in terminalIDs {
                recordAppEvent(
                    .surfaceCloseFailed,
                    correlationID: terminalID,
                    failure: .policyUnavailable
                )
            }
            return .failure(.unsupported(hostDisplayName: workspaceHostDisplayName(for: id)))
        }
        let result = await sendWorkspaceMutation(
            method: "workspace.close",
            params: workspaceMutationParams(id: id),
            id: id,
            actionName: "close"
        )
        for terminalID in terminalIDs {
            switch result {
            case .success:
                recordAppEvent(.surfaceCloseSucceeded, correlationID: terminalID)
            case .failure(let error):
                recordAppEvent(
                    .surfaceCloseFailed,
                    correlationID: terminalID,
                    failure: error.diagnosticFailureKind
                )
            }
        }
        return result
    }

    /// Move a workspace to a new group/order on the Mac, then re-sync the list.
    /// - Parameters:
    ///   - id: The workspace to move.
    ///   - groupID: The target group, or `nil` to ungroup.
    ///   - beforeWorkspaceID: The workspace that should follow the moved row.
    ///   - movesGroup: Whether the moved row is a group header.
    /// - Returns: `success` when the Mac accepted the move, otherwise the
    ///   failure the UI should surface.
    @discardableResult
    public func moveWorkspace(
        id: MobileWorkspacePreview.ID,
        toGroup groupID: MobileWorkspaceGroupPreview.ID?,
        before beforeWorkspaceID: MobileWorkspacePreview.ID?,
        movesGroup: Bool = false
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        let reorderStartedAt = appDiagnosticNow()
        recordAppEvent(.workspaceReorderStarted, correlationID: id.rawValue)
        MobileDebugLog.anchormux(
            "move.request id=\(id.rawValue.suffix(6)) group=\(groupID?.rawValue.suffix(6) ?? "root") before=\(beforeWorkspaceID?.rawValue.suffix(6) ?? "end") movesGroup=\(movesGroup)"
        )
        guard workspaceActionCapabilities(for: id).supportsMoveActions else {
            recordAppEvent(
                .workspaceMutationUnavailable,
                correlationID: id.rawValue,
                failure: .policyUnavailable
            )
            MobileDebugLog.anchormux("move.blocked gate=supportsMoveActions id=\(id.rawValue.suffix(6))")
            recordAppEvent(
                .workspaceReorderFailed,
                correlationID: id.rawValue,
                startedAt: reorderStartedAt,
                failure: .policyUnavailable
            )
            return .failure(.unsupported(hostDisplayName: workspaceHostDisplayName(for: id)))
        }
        let target = workspaceMutationTarget(for: id)
        let hostDisplayName = workspaceMutationHostDisplayName(
            target: target,
            fallback: workspaceHostDisplayName(for: id)
        )
        guard macScopedWorkspaceMutationIsAuthorized(target: target) else {
            recordAppEvent(
                .workspaceMutationUnavailable,
                correlationID: id.rawValue,
                failure: .authorizationFailed
            )
            MobileDebugLog.anchormux("move.blocked gate=macScopedMutationAuthorization id=\(id.rawValue.suffix(6))")
            recordAppEvent(
                .workspaceReorderFailed,
                correlationID: id.rawValue,
                startedAt: reorderStartedAt,
                failure: .authorizationFailed
            )
            return .failure(.authorizationFailed(hostDisplayName: hostDisplayName))
        }
        var params = workspaceMutationParams(id: id)
        if let groupID {
            params["group_id"] = remoteWorkspaceGroupID(for: groupID).rawValue
        }
        if let beforeWorkspaceID {
            params["before_workspace_id"] = remoteWorkspaceID(for: beforeWorkspaceID).rawValue
        }
        if movesGroup {
            params["move_group"] = true
        }
        let result = await sendWorkspaceMutation(
            method: "workspace.move",
            params: params,
            target: target,
            hostDisplayName: hostDisplayName,
            logID: id.rawValue,
            actionName: "move",
            isMacScoped: true
        )
        switch result {
        case .success:
            MobileDebugLog.anchormux("move.sent ok id=\(id.rawValue.suffix(6))")
            recordAppEvent(
                .workspaceReorderSucceeded,
                correlationID: id.rawValue,
                startedAt: reorderStartedAt
            )
        case .failure(let error):
            // Failure payloads include the user-visible Mac name. The event and
            // scoped workspace suffix are sufficient for move diagnostics.
            MobileDebugLog.anchormux("move.sent FAILED id=\(id.rawValue.suffix(6))")
            recordAppEvent(
                .workspaceReorderFailed,
                correlationID: id.rawValue,
                startedAt: reorderStartedAt,
                failure: error.diagnosticFailureKind
            )
        }
        return result
    }

    /// Pin or unpin a workspace group on the Mac.
    /// - Parameters:
    ///   - id: The group to update.
    ///   - pinned: `true` to pin, `false` to unpin.
    /// - Returns: `success` when the Mac accepted the request, otherwise the
    ///   failure the UI should surface.
    @discardableResult
    public func setWorkspaceGroupPinned(
        id: MobileWorkspaceGroupPreview.ID,
        _ pinned: Bool
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        await sendWorkspaceGroupMutation(
            id: id,
            action: pinned ? "pin" : "unpin",
            title: nil,
            actionName: pinned ? "pin_group" : "unpin_group"
        )
    }

    /// Rename a workspace group on the Mac.
    /// - Parameters:
    ///   - id: The group to rename.
    ///   - title: The new title. Whitespace-only titles are ignored.
    /// - Returns: `success` when the Mac accepted the request, otherwise the
    ///   failure the UI should surface.
    @discardableResult
    public func renameWorkspaceGroup(
        id: MobileWorkspaceGroupPreview.ID,
        title: String
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success(()) }
        return await sendWorkspaceGroupMutation(
            id: id,
            action: "rename",
            title: trimmed,
            actionName: "rename_group"
        )
    }

    /// Dissolve a workspace group on the Mac, keeping its workspaces.
    /// - Parameter id: The group to dissolve.
    /// - Returns: `success` when the Mac accepted the request, otherwise the
    ///   failure the UI should surface.
    @discardableResult
    public func ungroupWorkspaceGroup(
        id: MobileWorkspaceGroupPreview.ID
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        await sendWorkspaceGroupMutation(id: id, action: "ungroup", title: nil, actionName: "ungroup_group")
    }

    /// Delete a workspace group on the Mac, including its workspaces.
    /// - Parameter id: The group to delete.
    /// - Returns: `success` when the Mac accepted the request, otherwise the
    ///   failure the UI should surface.
    @discardableResult
    public func deleteWorkspaceGroup(
        id: MobileWorkspaceGroupPreview.ID
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        await sendWorkspaceGroupMutation(id: id, action: "delete", title: nil, actionName: "delete_group")
    }

    /// Create a workspace group on the foreground Mac.
    /// - Parameter title: Optional group title. Whitespace-only titles use the Mac's default auto-name.
    /// - Returns: `success` when the Mac accepted the request, otherwise the
    ///   failure the UI should surface.
    @discardableResult
    public func createWorkspaceGroup(
        title: String? = nil
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        let target = WorkspaceMutationTarget(
            client: remoteClient,
            isForeground: true,
            macDeviceID: foregroundMacDeviceID
        )
        let hostDisplayName = workspaceMutationHostDisplayName(target: target, fallback: nil)
        guard supportedHostCapabilities.contains("workspace.group_create.v1") else {
            recordAppEvent(.workspaceMutationUnavailable, failure: .policyUnavailable)
            return .failure(.unsupported(hostDisplayName: hostDisplayName))
        }
        guard macScopedWorkspaceMutationIsAuthorized(target: target) else {
            recordAppEvent(.workspaceMutationUnavailable, failure: .authorizationFailed)
            return .failure(.authorizationFailed(hostDisplayName: hostDisplayName))
        }
        var params: [String: Any] = [:]
        if let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            params["title"] = trimmed
        }
        return await sendWorkspaceMutation(
            method: "workspace.group.create",
            params: params,
            target: target,
            hostDisplayName: hostDisplayName,
            logID: "foreground",
            actionName: "create_group",
            isMacScoped: true
        )
    }

    private func workspaceActionCapabilities(for id: MobileWorkspacePreview.ID) -> MobileWorkspaceActionCapabilities {
        workspaces.first { $0.id == id }?.actionCapabilities ?? .none
    }

    private func workspaceGroupActionCapabilities(for id: MobileWorkspaceGroupPreview.ID) -> MobileWorkspaceActionCapabilities {
        guard let anchorWorkspaceID = workspaceGroups.first(where: { $0.id == id })?.anchorWorkspaceID else {
            return .none
        }
        return workspaceActionCapabilities(for: anchorWorkspaceID)
    }

    private func macScopedWorkspaceMutationIsAuthorized(target: WorkspaceMutationTarget) -> Bool {
        guard let client = target.client else { return true }
        let now = runtime?.now() ?? Date()
        let policy = MobileShellWorkspaceMutationTicketPolicy(now: now)
        if target.isForeground {
            return policy.allowsMacScopedWorkspaceMutations(
                activeTicket ?? client.attachTicket,
                hostAuthorizesByAccount: hostAuthorizesAccountScopedMutations
            )
        }
        let subscription = target.ownerKey.flatMap { secondaryMacSubscriptions[$0] }
        let ticket = subscription?.ticket ?? client.attachTicket
        return policy.allowsMacScopedWorkspaceMutations(
            ticket,
            hostAuthorizesByAccount: subscription?.supportedHostCapabilities
                .contains(Self.workspaceMutationAccountAuthCapability) ?? false
        )
    }

    private func hostAuthorizesAccountScopedMutations(target: WorkspaceMutationTarget) -> Bool {
        if target.isForeground {
            return hostAuthorizesAccountScopedMutations
        }
        return target.ownerKey.flatMap { secondaryMacSubscriptions[$0] }?
            .supportedHostCapabilities.contains(Self.workspaceMutationAccountAuthCapability) ?? false
    }

    private func sendWorkspaceMutation(
        method: String,
        params: [String: Any],
        id: MobileWorkspacePreview.ID,
        actionName: String,
        refreshAfterMutation: Bool = true
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        let target = workspaceMutationTarget(for: id)
        return await sendWorkspaceMutation(
            method: method,
            params: params,
            target: target,
            hostDisplayName: workspaceMutationHostDisplayName(
                target: target,
                fallback: workspaceHostDisplayName(for: id)
            ),
            logID: id.rawValue,
            actionName: actionName,
            refreshAfterMutation: refreshAfterMutation
        )
    }

    private func sendWorkspaceGroupMutation(
        id: MobileWorkspaceGroupPreview.ID,
        action: String,
        title: String?,
        actionName: String
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        let target = workspaceGroupMutationTarget(for: id)
        let hostDisplayName = workspaceGroupHostDisplayName(for: id, target: target)
        guard workspaceGroupActionCapabilities(for: id).supportsGroupActions else {
            recordAppEvent(
                .workspaceMutationUnavailable,
                correlationID: id.rawValue,
                failure: .policyUnavailable
            )
            MobileDebugLog.anchormux("workspace.mutation blocked action=\(actionName) id=\(id.rawValue) reason=capability")
            return .failure(.unsupported(hostDisplayName: hostDisplayName))
        }
        guard macScopedWorkspaceMutationIsAuthorized(target: target) else {
            recordAppEvent(
                .workspaceMutationUnavailable,
                correlationID: id.rawValue,
                failure: .authorizationFailed
            )
            MobileDebugLog.anchormux("workspace.mutation blocked action=\(actionName) id=\(id.rawValue) reason=scope")
            return .failure(.authorizationFailed(hostDisplayName: hostDisplayName))
        }
        var params: [String: Any] = [
            "group_id": remoteWorkspaceGroupID(for: id).rawValue,
            "action": action,
        ]
        if let title {
            params["title"] = title
        }
        return await sendWorkspaceMutation(
            method: "workspace.group.action",
            params: params,
            target: target,
            hostDisplayName: hostDisplayName,
            logID: id.rawValue,
            actionName: actionName,
            isMacScoped: true
        )
    }

    private func sendWorkspaceMutation(
        method: String,
        params: [String: Any],
        target: WorkspaceMutationTarget,
        hostDisplayName: String?,
        logID: String,
        actionName: String,
        refreshAfterMutation: Bool = true,
        isMacScoped: Bool = false
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        let diagnosticKinds = workspaceMutationDiagnosticKinds(actionName: actionName)
        let startedAt = appDiagnosticNow()
        if let start = diagnosticKinds.start {
            recordAppEvent(start, correlationID: logID)
        }
        // Route the mutation to the Mac that actually OWNS this workspace. The
        // aggregated list can include rows from secondary Macs, whose connection is
        // not `remoteClient`; sending every mutation to the foreground client would
        // silently hit the wrong Mac (fail, or — with a colliding workspace id —
        // mutate a foreground workspace). The foreground path is unchanged for
        // foreground-owned (or single-Mac / anonymous) rows.
        guard let client = target.client else {
            MobileDebugLog.anchormux("workspace.mutation blocked action=\(actionName) id=\(logID) reason=no_route")
            // Owner is a known non-foreground Mac with no live connection: can't
            // deliver. Snap the row back to the authoritative state instead of
            // misrouting to the foreground Mac.
            if refreshAfterMutation {
                await refreshAfterWorkspaceMutation(target)
            }
            recordAppEvent(
                diagnosticKinds.failure,
                correlationID: logID,
                startedAt: startedAt,
                failure: .noRoute
            )
            return .failure(.notConnected(hostDisplayName: hostDisplayName))
        }
        let generation = connectionGeneration
        MobileDebugLog.anchormux("workspace.mutation sending action=\(actionName) id=\(logID) foreground=\(target.isForeground)")
        do {
            let request = try MobileCoreRPCClient.requestData(method: method, params: params)
            let attachTicketPolicy: MobileCoreRPCAttachTicketPolicy =
                isMacScoped && hostAuthorizesAccountScopedMutations(target: target)
                    ? .omit
                    : .whenCovered
            _ = try await client.sendRequest(
                request,
                attachTicketPolicy: attachTicketPolicy
            )
        } catch {
            // Diagnostics carry only the bounded failure vocabulary plus the
            // short RPC code: an rpcError message is an arbitrary host string
            // and must never be retained in exported diagnostics.
            let failureKind = DiagnosticFailureKind.classify(error)
            var rpcCode = "none"
            if case let MobileShellConnectionError.rpcError(code, _) = error {
                rpcCode = code ?? "unknown"
            }
            MobileDebugLog.anchormux("workspace.mutation failed action=\(actionName) id=\(logID) kind=\(failureKind) code=\(rpcCode)")
            if disconnectForAuthorizationFailureIfNeeded(error) {
                recordAppEvent(
                    diagnosticKinds.failure,
                    correlationID: logID,
                    startedAt: startedAt,
                    failure: failureKind
                )
                return .failure(.authorizationFailed(hostDisplayName: hostDisplayName))
            }
            // Only the foreground connection's health drives the foreground
            // unavailable/reconnect UI; a failed write to a secondary Mac must not
            // tear the foreground session down.
            if target.isForeground {
                handleMacAvailabilityFailureIfCurrent(
                    after: error,
                    expectedClient: client,
                    expectedGeneration: generation
                )
            }
            mobileShellLog.error("workspace mutation failed action=\(actionName, privacy: .public) id=\(logID, privacy: .public) kind=\(String(describing: failureKind), privacy: .public) error=\(String(describing: error), privacy: .private)")
            if refreshAfterMutation {
                await refreshAfterWorkspaceMutation(target)
            }
            recordAppEvent(
                diagnosticKinds.failure,
                correlationID: logID,
                startedAt: startedAt,
                failure: failureKind
            )
            return .failure(workspaceMutationFailure(error, hostDisplayName: hostDisplayName))
        }
        // Re-sync the authoritative list for the Mac we actually mutated.
        if refreshAfterMutation {
            await refreshAfterWorkspaceMutation(target)
        }
        MobileDebugLog.anchormux("workspace.mutation accepted action=\(actionName) id=\(logID)")
        recordAppEvent(
            diagnosticKinds.success,
            correlationID: logID,
            startedAt: startedAt
        )
        return .success(())
    }

    private func workspaceMutationDiagnosticKinds(
        actionName: String
    ) -> (
        start: DiagnosticAppEventKind?,
        success: DiagnosticAppEventKind,
        failure: DiagnosticAppEventKind
    ) {
        switch actionName {
        case "rename":
            (.workspaceRenameStarted, .workspaceRenameSucceeded, .workspaceRenameFailed)
        case "close":
            (.workspaceCloseStarted, .workspaceCloseSucceeded, .workspaceCloseFailed)
        case "move":
            (.workspaceMoveStarted, .workspaceMoveSucceeded, .workspaceMoveFailed)
        case "create_group":
            (.workspaceGroupCreateStarted, .workspaceGroupCreateSucceeded, .workspaceGroupCreateFailed)
        case "rename_group":
            (.workspaceGroupRenameStarted, .workspaceGroupRenameSucceeded, .workspaceGroupRenameFailed)
        case "delete_group", "ungroup_group":
            (.workspaceGroupDeleteStarted, .workspaceGroupDeleteSucceeded, .workspaceGroupDeleteFailed)
        case "mark_read", "mark_unread":
            (nil, .workspaceReadStateChanged, .workspaceReadStateChangeFailed)
        default:
            (nil, .workspaceCustomizationChanged, .workspaceCustomizationChangeFailed)
        }
    }

    private func workspaceMutationParams(id: MobileWorkspacePreview.ID) -> [String: Any] {
        var params: [String: Any] = [
            "workspace_id": remoteWorkspaceID(for: id).rawValue,
            "client_id": clientID,
        ]
        if let windowID = workspaces.first(where: { $0.id == id })?.windowID {
            params["window_id"] = windowID
        }
        return params
    }

    private func workspaceGroupMutationTarget(for id: MobileWorkspaceGroupPreview.ID) -> WorkspaceMutationTarget {
        guard let anchorWorkspaceID = workspaceGroups.first(where: { $0.id == id })?.anchorWorkspaceID else {
            return WorkspaceMutationTarget(
                client: remoteClient,
                isForeground: true,
                macDeviceID: foregroundMacDeviceID
            )
        }
        return workspaceMutationTarget(for: anchorWorkspaceID)
    }

    func workspaceMutationFailure(
        _ error: any Error,
        hostDisplayName: String?
    ) -> MobileWorkspaceMutationFailure {
        guard let connectionError = error as? MobileShellConnectionError else {
            return .rejected(hostDisplayName: hostDisplayName)
        }
        switch connectionError {
        case .connectionClosed, .transportWriteTimedOut,
             .routeCleanupBlocked:
            return .notConnected(hostDisplayName: hostDisplayName)
        case .requestTimedOut, .connectAttemptGated:
            return .requestTimedOut(hostDisplayName: hostDisplayName)
        case .attachTicketExpired, .authorizationFailed, .accountMismatch, .insecureManualRoute:
            return .authorizationFailed(hostDisplayName: hostDisplayName)
        case let .rpcError(code, _):
            let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let normalizedCode,
               ["unauthorized", "forbidden", "invalid_token", "token_expired", "expired_token", "auth_required", "account_mismatch"].contains(normalizedCode) {
                return .authorizationFailed(hostDisplayName: hostDisplayName)
            }
            if normalizedCode == "unavailable" { return .notConnected(hostDisplayName: hostDisplayName) }
            if normalizedCode == "request_timeout" { return .requestTimedOut(hostDisplayName: hostDisplayName) }
            if normalizedCode == "busy" { return .busy(hostDisplayName: hostDisplayName) }
            if normalizedCode == "invalid_working_directory" { return .invalidWorkingDirectory(hostDisplayName: hostDisplayName) }
            if normalizedCode == "persistence_failed" { return .persistenceUnavailable(hostDisplayName: hostDisplayName) }
            if normalizedCode == "already_completed" { return .alreadyCompleted(hostDisplayName: hostDisplayName) }
            return .rejected(hostDisplayName: hostDisplayName)
        case .invalidResponse:
            return .rejected(hostDisplayName: hostDisplayName)
        }
    }

    private func workspaceMutationHostDisplayName(
        target: WorkspaceMutationTarget,
        fallback: String?
    ) -> String? {
        if let ownerKey = target.ownerKey ?? target.macDeviceID.map({
               MacPairingKey(macDeviceID: $0, instanceTag: nil)
           }),
           let displayName = workspacesByMac[ownerKey]?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            return displayName
        }
        let trimmedConnectedHostName = connectedHostName.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isForeground, !trimmedConnectedHostName.isEmpty {
            return trimmedConnectedHostName
        }
        guard let fallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fallback.isEmpty else {
            return nil
        }
        return fallback
    }

    private func workspaceHostDisplayName(for id: MobileWorkspacePreview.ID) -> String? {
        workspaces.first(where: { $0.id == id })?.macDisplayName
    }

    private func workspaceGroupHostDisplayName(
        for id: MobileWorkspaceGroupPreview.ID,
        target: WorkspaceMutationTarget
    ) -> String? {
        guard let anchorWorkspaceID = workspaceGroups.first(where: { $0.id == id })?.anchorWorkspaceID else {
            return workspaceMutationHostDisplayName(target: target, fallback: nil)
        }
        return workspaceMutationHostDisplayName(
            target: target,
            fallback: workspaceHostDisplayName(for: anchorWorkspaceID)
        )
    }

    /// Collapse or expand a workspace group on THIS device only.
    ///
    /// Folder collapse is a per-device UI preference, not shared state: collapsing
    /// a group on the phone must not collapse it on the Mac. So this records the
    /// choice in the device-local `groupCollapseStore` and updates the in-memory
    /// `workspaceGroups` for an immediate, authoritative render. Nothing is sent to
    /// the Mac, and a later Mac `workspace.updated` will not override it (the
    /// workspace-list ingest re-applies this store). The `async` signature is kept
    /// for call-site compatibility; the work is synchronous on the main actor.
    /// - Parameters:
    ///   - id: The group to collapse or expand.
    ///   - collapsed: `true` to collapse (hide members), `false` to expand.
    public func setWorkspaceGroupCollapsed(id: MobileWorkspaceGroupPreview.ID, _ collapsed: Bool) async {
        guard let index = workspaceGroups.firstIndex(where: { $0.id == id }) else { return }
        groupCollapseStore.set(
            workspaceGroups[index].collapseStateID,
            collapsed: collapsed
        )
        workspaceGroups[index].isCollapsed = collapsed
        recordAppEvent(
            .workspaceGroupCollapsedChanged,
            correlationID: id.rawValue,
            count: collapsed ? 1 : 0
        )
    }

    /// Choose how the aggregated All Computers list orders its rows, on THIS
    /// device only. Persists via the device-local sort store and rebuilds the
    /// derived list so the change renders immediately; nothing is sent to a
    /// Mac (each Mac keeps its own sidebar order).
    public func setWorkspaceSortMode(_ mode: MobileWorkspaceSortMode) {
        guard workspaceSortMode != mode else { return }
        workspaceSortStore.setMode(mode)
        workspaceSortMode = mode
        recomputeDerivedWorkspaceState()
        recordAppEvent(.workspaceSortChanged)
    }

    /// Persist the user's computer order for
    /// ``MobileWorkspaceSortMode/computerPriority``, highest priority first,
    /// as device-plus-build pairing ids. Device-local, like the mode.
    public func setWorkspaceComputerPriority(_ computerIDs: [String]) {
        guard workspaceComputerPriority != computerIDs else { return }
        workspaceSortStore.setComputerPriority(computerIDs)
        workspaceComputerPriority = computerIDs
        recomputeDerivedWorkspaceState()
        recordAppEvent(.workspaceComputerOrderChanged, count: computerIDs.count)
    }

    /// Upgrade pre-build-scoped computer-order entries after paired Macs load.
    /// A legacy bare device id expands to every currently stored pairing for
    /// that physical device, preserving the user's order across Stable,
    /// Nightly, and untagged rows without making the bare id a new wildcard.
    func migrateLegacyWorkspaceComputerPriority(loadedMacs: [MobilePairedMac]) {
        guard workspaceSortStore.needsComputerIdentityMigration else { return }
        var migrated: [String] = []
        for computerID in workspaceComputerPriority {
            let identity = CmxMacAppInstanceIdentity(id: computerID)
            guard identity.instanceTag == nil else {
                if !migrated.contains(identity.id) { migrated.append(identity.id) }
                continue
            }
            let matches = loadedMacs.filter {
                CmxMacAppInstanceIdentity(
                    macDeviceID: $0.macDeviceID,
                    instanceTag: $0.instanceTag
                ).macDeviceID == identity.macDeviceID
            }
            if matches.isEmpty {
                if !migrated.contains(identity.id) { migrated.append(identity.id) }
                continue
            }
            for mac in matches.sorted(by: {
                let lhsTag = CmxMacAppInstanceIdentity(
                    macDeviceID: $0.macDeviceID,
                    instanceTag: $0.instanceTag
                ).instanceTag
                let rhsTag = CmxMacAppInstanceIdentity(
                    macDeviceID: $1.macDeviceID,
                    instanceTag: $1.instanceTag
                ).instanceTag
                if lhsTag == nil { return rhsTag != nil }
                if rhsTag == nil { return false }
                return lhsTag! < rhsTag!
            }) {
                let pairingID = CmxMacAppInstanceIdentity(
                    macDeviceID: mac.macDeviceID,
                    instanceTag: mac.instanceTag
                ).id
                if !migrated.contains(pairingID) { migrated.append(pairingID) }
            }
        }
        workspaceSortStore.migrateLegacyComputerPriority(migrated)
        workspaceComputerPriority = migrated
    }

    /// The stored computer order expanded with each app instance's stored
    /// device aliases, so a per-Mac state that reports an alias id still ranks
    /// with its computer. The instance tag stays attached to every alias;
    /// otherwise prioritizing Nightly would also prioritize Stable.
    func expandedWorkspaceComputerPriority() -> [String] {
        var expanded: [String] = []
        for computerID in workspaceComputerPriority {
            let identity = MobilePairedMac.pairingIdentity(from: computerID)
            for aliasDeviceID in pairedMacAliasIDs(
                for: identity.macDeviceID,
                instanceTag: identity.instanceTag
            ) {
                let aliasComputerID = MobilePairedMac.pairingID(
                    macDeviceID: aliasDeviceID,
                    instanceTag: identity.instanceTag
                )
                if !expanded.contains(aliasComputerID) {
                    expanded.append(aliasComputerID)
                }
            }
        }
        return expanded
    }
}
