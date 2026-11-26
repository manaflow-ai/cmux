import CmuxAgentJournal
import Foundation

/// What `agent.message.settings` acts on, resolved on the main actor.
private struct AgentMessageSettingsTarget: Sendable {
    let scope: AgentMessageRecipientScope
    /// The surface or workspace id the opt-out is stored under.
    let id: UUID
    let ref: String
    let workspaceTitle: String
    /// The workspace a surface target is in now, so a status read can say
    /// when that workspace turned messages off. Nil for a workspace target.
    let surfaceWorkspaceId: UUID?
}

extension TerminalController {
    /// `agent.message.settings`: reads, or with `enabled` sets, whether one
    /// surface or workspace receives agent messages. Defaults to the caller's
    /// surface (`surface_id`). Not on the remote relay allowlist.
    nonisolated func agentMessageSettings(params: [String: Any]) async -> V2CallResult {
        let scope: AgentMessageRecipientScope
        switch Self.agentMessageTrimmed(params["scope"]) ?? "surface" {
        case "surface": scope = .surface
        case "workspace": scope = .workspace
        default:
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.agentMessage.error.invalidScope",
                    defaultValue: "Scope must be surface or workspace."
                ),
                data: nil
            )
        }
        let target = Self.agentMessageTrimmed(params["target"])
        let callerSurface = Self.agentMessageSurfaceUUID(params["surface_id"]).flatMap(UUID.init(uuidString:))
        let callerWorkspace = Self.agentMessageSurfaceUUID(params["workspace_id"]).flatMap(UUID.init(uuidString:))
        guard target != nil || callerSurface != nil || (scope == .workspace && callerWorkspace != nil) else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.agentMessage.error.missingSettingsTarget",
                    defaultValue: "Give a target workspace or surface, or run this inside a cmux surface."
                ),
                data: nil
            )
        }

        let resolved: AgentMessageSettingsTarget?
        do {
            resolved = try await v2MainAsync {
                self.agentMessageSettingsTarget(
                    scope: scope,
                    target: target,
                    callerSurface: callerSurface,
                    callerWorkspace: callerWorkspace
                )
            }
        } catch {
            return Self.agentMessageMainHopFailure(error)
        }
        guard let resolved else {
            return .err(
                code: "not_found",
                message: String(
                    localized: "socket.agentMessage.error.targetNotFound",
                    defaultValue: "No workspace or surface matches that target."
                ),
                data: ["target": target ?? callerSurface?.uuidString ?? ""]
            )
        }

        var failed: [AgentMessage] = []
        if let enabled = params["enabled"] as? Bool {
            var open: AgentMessageOpenRecipients?
            if !enabled, AgentMessageCenter.store.isAtOptOutCapacity {
                do {
                    open = try await v2MainAsync { AgentMessageCenter.openRecipientsIfAtCapacity() }
                } catch {
                    return Self.agentMessageMainHopFailure(error)
                }
            }
            do {
                failed = try AgentMessageCenter.setReceivingEnabled(enabled, scope: resolved.scope, id: resolved.id, openRecipients: open)
            } catch let error as AgentMessagePersistenceError {
                return .err(
                    code: "storage_failed",
                    message: String(
                        localized: "socket.agentMessage.error.settingNotSaved",
                        defaultValue: "The setting was not changed: cmux could not save it to the message journal."
                    ),
                    data: ["reason": error.reason]
                )
            } catch {
                return .err(code: "internal_error", message: String(describing: error), data: nil)
            }
        }
        var result: [String: Any] = [
            "scope": resolved.scope.rawValue,
            "id": resolved.id.uuidString,
            "ref": resolved.ref,
            "workspace_title": resolved.workspaceTitle,
            "receiving": !AgentMessageCenter.isReceivingDisabled(scope: resolved.scope, id: resolved.id),
            "messages_enabled": AgentMessageCenter.isEnabled(),
            "failed": failed.map(\.id),
        ]
        // A surface whose workspace is off receives nothing, whatever its own setting.
        if let workspaceId = resolved.surfaceWorkspaceId {
            result["workspace_receiving"] = !AgentMessageCenter.isReceivingDisabled(scope: .workspace, id: workspaceId)
        }
        return .ok(result)
    }

    @MainActor
    private func agentMessageSettingsTarget(
        scope: AgentMessageRecipientScope,
        target: String?,
        callerSurface: UUID?,
        callerWorkspace: UUID?
    ) -> AgentMessageSettingsTarget? {
        let surfaceId: UUID?
        let workspace: Workspace?
        if let target {
            // The same resolution `cmux agent message` uses, so turning off
            // `<target>` silences exactly the agent a send to it would reach.
            guard let recipient = agentMessageResolveRecipient(target) else { return nil }
            surfaceId = recipient.surfaceId
            workspace = AppDelegate.shared?.tabManagerFor(tabId: recipient.workspaceId)?
                .workspacesById[recipient.workspaceId]
        } else if let callerSurface {
            surfaceId = callerSurface
            workspace = AppDelegate.shared?.workspaceContainingPanel(
                panelId: callerSurface,
                preferredWorkspaceId: callerWorkspace
            )?.workspace
        } else if let callerWorkspace {
            surfaceId = nil
            workspace = AppDelegate.shared?.tabManagerFor(tabId: callerWorkspace)?.workspacesById[callerWorkspace]
        } else {
            return nil
        }
        guard let workspace else { return nil }
        switch scope {
        case .surface:
            guard let surfaceId, workspace.panels[surfaceId] != nil else { return nil }
            return AgentMessageSettingsTarget(
                scope: .surface,
                id: surfaceId,
                ref: v2EnsureHandleRef(kind: .surface, uuid: surfaceId),
                workspaceTitle: workspace.title,
                surfaceWorkspaceId: workspace.id
            )
        case .workspace:
            return AgentMessageSettingsTarget(
                scope: .workspace,
                id: workspace.id,
                ref: v2EnsureHandleRef(kind: .workspace, uuid: workspace.id),
                workspaceTitle: workspace.title,
                surfaceWorkspaceId: nil
            )
        }
    }

    /// The error for a send the off switches refused. Names the recipient.
    nonisolated static func agentMessageBlockedResult(
        _ block: AgentMessageBlock,
        recipient: AgentMessageRecipient?
    ) -> V2CallResult {
        var data: [String: Any] = ["reason": block.reason]
        if let recipient {
            data["recipient_surface_ref"] = recipient.surfaceRef
            data["recipient_workspace_ref"] = recipient.workspaceRef
            data["recipient_workspace_title"] = recipient.workspaceTitle
        }
        let label = recipient.map { recipient -> String in
            switch block {
            case .workspaceDisabled:
                return recipient.workspaceTitle.isEmpty ? recipient.workspaceRef : recipient.workspaceTitle
            case .messagesDisabled, .recipientDisabled:
                return recipient.workspaceTitle.isEmpty
                    ? recipient.surfaceRef
                    : "\(recipient.surfaceRef) (\(recipient.workspaceTitle))"
            }
        }
        return .err(
            code: block.reason,
            message: AgentMessageCenter.blockedMessage(block, recipientLabel: label),
            data: data
        )
    }
}

extension AgentMessageCenter {
    /// User-facing text for a refused send. `recipientLabel` names the
    /// recipient; without one the stored id is used.
    static func blockedMessage(_ block: AgentMessageBlock, recipientLabel: String?) -> String {
        switch block {
        case .messagesDisabled:
            return String(
                localized: "agentMessage.error.messagesDisabled",
                defaultValue: "Agent messages are turned off (agentMessages.enabled is false)."
            )
        case .recipientDisabled(let surfaceId):
            return String(
                format: String(
                    localized: "agentMessage.error.recipientDisabled",
                    defaultValue: "Recipient %@ has messages disabled."
                ),
                recipientLabel ?? surfaceId
            )
        case .workspaceDisabled(let workspaceId):
            return String(
                format: String(
                    localized: "agentMessage.error.workspaceDisabled",
                    defaultValue: "Recipient workspace %@ has messages disabled."
                ),
                recipientLabel ?? workspaceId
            )
        }
    }

    /// The refused-send text for an error thrown by the store, or `nil` when
    /// the error is something else.
    static func blockedMessage(for error: any Error) -> String? {
        guard let blocked = error as? AgentMessageBlockedError else { return nil }
        return blockedMessage(blocked.block, recipientLabel: nil)
    }
}
