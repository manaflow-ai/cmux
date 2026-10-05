import CmuxAgentJournal
import CmuxControlSocket
import Foundation

/// Where a message goes, resolved on the main actor.
struct AgentMessageRecipient: Sendable {
    let surfaceId: UUID
    let workspaceId: UUID
    let surfaceRef: String
    let workspaceRef: String
    let workspaceTitle: String
    /// True when cmux has seen agent hook activity on the surface.
    let hasAgent: Bool
}

extension TerminalController {
    /// Handles `agent.message.*` on the socket worker. Every method answers
    /// at once; hooks poll instead of holding a connection open.
    nonisolated func agentMessageResponse(_ request: ControlRequest) async -> String {
        let params = request.params.mapValues(\.foundationObject)
        let result: V2CallResult
        switch request.method {
        case "agent.message.send":
            result = await agentMessageSend(params: params)
        case "agent.message.list":
            result = await agentMessageList(params: params)
        case "agent.message.claim":
            result = agentMessageClaim(params: params)
        case "agent.message.ack":
            result = agentMessageAck(params: params)
        case "agent.message.mark_read":
            result = agentMessageMarkRead(params: params)
        case "agent.message.poll":
            result = await agentMessagePoll(params: params)
        case "agent.message.settings":
            result = await agentMessageSettings(params: params)
        default:
            result = .err(
                code: "method_not_found",
                message: String(localized: "socket.error.unknownMethod", defaultValue: "Unknown method"),
                data: nil
            )
        }
        return Self.v2Encoder.response(id: request.id, Self.controlCallResult(fromLegacy: result))
    }

    // MARK: - Methods

    private nonisolated func agentMessageSend(params: [String: Any]) async -> V2CallResult {
        let body = (params["body"] as? String) ?? ""
        let senderName = (params["from"] as? String) ?? ""
        let senderSurfaceId = Self.agentMessageSurfaceUUID(params["sender_surface_id"])
        let senderWorkspaceId = Self.agentMessageSurfaceUUID(params["sender_workspace_id"])
        let replyTo = Self.agentMessageTrimmed(params["reply_to"])
        let hasRelayProvenance = params[WorkspaceRemoteRelayCommandRewriter.remoteWorkspaceIDKey] != nil
        let relayOwnerWorkspaceID = Self.agentMessageSurfaceUUID(
            params[WorkspaceRemoteRelayCommandRewriter.remoteWorkspaceIDKey]
        ).flatMap(UUID.init(uuidString:))
        let relayConnectionID = Self.agentMessageSurfaceUUID(
            params[WorkspaceRemoteRelayCommandRewriter.connectionIDKey]
        ).flatMap(UUID.init(uuidString:))
        let store = AgentMessageCenter.store
        // Checked before resolving the target so the reason is the switch,
        // not a lookup failure. The store checks again when it appends.
        guard AgentMessageCenter.isEnabled() else {
            return Self.agentMessageBlockedResult(.messagesDisabled, recipient: nil)
        }

        let targetString: String
        if let replyTo {
            guard let parent = store.message(id: replyTo) else {
                return .err(code: "not_found", message: Self.agentMessageUnknownIdMessage(replyTo), data: nil)
            }
            guard let parentSender = parent.senderSurfaceId else {
                return .err(
                    code: "invalid_params",
                    message: String(
                        localized: "socket.agentMessage.error.noReplyAddress",
                        defaultValue: "That message has no sender surface to reply to."
                    ),
                    data: nil
                )
            }
            targetString = parentSender
        } else if let target = Self.agentMessageTrimmed(params["target"]) {
            targetString = target
        } else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.agentMessage.error.missingTarget",
                    defaultValue: "Give a target workspace or surface, or a message id to reply to."
                ),
                data: nil
            )
        }

        let recipientAndTitle: (AgentMessageRecipient?, String?)
        do {
            recipientAndTitle = try await v2MainAsync { () -> (AgentMessageRecipient?, String?) in
                let relaySurfaceIDs: Set<UUID>?
                if let relayOwnerWorkspaceID, let relayConnectionID {
                    relaySurfaceIDs = self.remoteRelayAgentMessageSurfaceIDs(
                        ownerWorkspaceID: relayOwnerWorkspaceID,
                        connectionID: relayConnectionID
                    )
                } else {
                    relaySurfaceIDs = nil
                }
                guard !hasRelayProvenance || relaySurfaceIDs != nil else {
                    return (nil, nil)
                }
                return (
                    self.agentMessageResolveRecipient(
                        targetString,
                        allowedSurfaceIDs: relaySurfaceIDs
                    ),
                    senderName.trimmingCharacters(in: .whitespaces).isEmpty
                        ? self.agentMessageWorkspaceTitle(surfaceId: senderSurfaceId, workspaceId: senderWorkspaceId)
                        : nil
                )
            }
        } catch {
            return Self.agentMessageMainHopFailure(error)
        }
        let (recipient, senderTitle) = recipientAndTitle
        guard let recipient else {
            return .err(
                code: "not_found",
                message: String(
                    localized: "socket.agentMessage.error.targetNotFound",
                    defaultValue: "No workspace or surface matches that target."
                ),
                data: ["target": targetString]
            )
        }

        let draft = AgentMessageDraft(
            senderName: senderTitle ?? senderName,
            senderSurfaceId: senderSurfaceId,
            senderWorkspaceId: senderWorkspaceId,
            recipientSurfaceId: recipient.surfaceId.uuidString,
            recipientWorkspaceId: recipient.workspaceId.uuidString,
            body: body,
            threadId: Self.agentMessageTrimmed(params["thread_id"]),
            inReplyTo: replyTo
        )
        do {
            let message = try store.append(draft)
            var payload = AgentMessageCenter.payload(message)
            payload["recipient_surface_ref"] = recipient.surfaceRef
            payload["recipient_workspace_ref"] = recipient.workspaceRef
            payload["recipient_workspace_title"] = recipient.workspaceTitle
            payload["recipient_has_agent"] = recipient.hasAgent
            return .ok(payload)
        } catch let error as AgentMessageBlockedError {
            return Self.agentMessageBlockedResult(error.block, recipient: recipient)
        } catch let error as AgentMessageValidationError {
            return .err(code: "invalid_params", message: Self.agentMessageValidationMessage(error), data: nil)
        } catch let error as AgentMessagePersistenceError {
            return .err(
                code: "storage_failed",
                message: String(
                    localized: "socket.agentMessage.error.notSaved",
                    defaultValue: "The message was not sent: cmux could not save it to the message journal."
                ),
                data: ["reason": error.reason]
            )
        } catch {
            return .err(code: "internal_error", message: String(describing: error), data: nil)
        }
    }

    private nonisolated func agentMessageList(params: [String: Any]) async -> V2CallResult {
        var surfaceId: String?
        if let target = Self.agentMessageTrimmed(params["surface"]) {
            let recipient: AgentMessageRecipient?
            let hasRelayProvenance = params[WorkspaceRemoteRelayCommandRewriter.remoteWorkspaceIDKey] != nil
            let relayOwnerWorkspaceID = Self.agentMessageSurfaceUUID(
                params[WorkspaceRemoteRelayCommandRewriter.remoteWorkspaceIDKey]
            ).flatMap(UUID.init(uuidString:))
            let relayConnectionID = Self.agentMessageSurfaceUUID(
                params[WorkspaceRemoteRelayCommandRewriter.connectionIDKey]
            ).flatMap(UUID.init(uuidString:))
            do {
                recipient = try await v2MainAsync { () -> AgentMessageRecipient? in
                    let relaySurfaceIDs: Set<UUID>?
                    if let relayOwnerWorkspaceID, let relayConnectionID {
                        relaySurfaceIDs = self.remoteRelayAgentMessageSurfaceIDs(
                            ownerWorkspaceID: relayOwnerWorkspaceID,
                            connectionID: relayConnectionID
                        )
                    } else {
                        relaySurfaceIDs = nil
                    }
                    guard !hasRelayProvenance || relaySurfaceIDs != nil else {
                        return nil
                    }
                    return self.agentMessageResolveRecipient(
                        target,
                        allowedSurfaceIDs: relaySurfaceIDs
                    )
                }
            } catch {
                return Self.agentMessageMainHopFailure(error)
            }
            guard let recipient else {
                return .err(
                    code: "not_found",
                    message: String(
                        localized: "socket.agentMessage.error.targetNotFound",
                        defaultValue: "No workspace or surface matches that target."
                    ),
                    data: ["target": target]
                )
            }
            surfaceId = recipient.surfaceId.uuidString
        }
        var states: Set<AgentMessageDeliveryState>?
        let rawStates: [String]
        if let single = params["state"] as? String {
            rawStates = [single]
        } else {
            rawStates = (params["state"] as? [String]) ?? []
        }
        if !rawStates.isEmpty {
            let parsed = rawStates.compactMap(AgentMessageDeliveryState.init(rawValue:))
            guard parsed.count == rawStates.count else {
                return .err(
                    code: "invalid_params",
                    message: String(
                        localized: "socket.agentMessage.error.invalidState",
                        defaultValue: "State must be queued, delivered, read or failed."
                    ),
                    data: nil
                )
            }
            states = Set(parsed)
        }
        let limit = min(max((params["limit"] as? Int) ?? 50, 1), 1_000)
        let messages = AgentMessageCenter.store.messages(surfaceId: surfaceId, states: states, limit: limit)
        return .ok(["messages": messages.map(AgentMessageCenter.payload)])
    }

    /// Used by synchronous hooks (prompt submit, Codex stop): hands over every
    /// queued message for the caller's surface.
    private nonisolated func agentMessageClaim(params: [String: Any]) -> V2CallResult {
        guard let surfaceId = Self.agentMessageSurfaceUUID(params["surface_id"]) else {
            return Self.agentMessageMissingSurface()
        }
        let store = AgentMessageCenter.store
        if params["mark_delivered_read"] as? Bool == true {
            store.markDeliveredRead(recipientSurfaceId: surfaceId)
        }
        let via = Self.agentMessageTrimmed(params["via"]) ?? "hook"
        let messages: [AgentMessage]
        var leaseID: String?
        if params["defer_delivery"] as? Bool == true {
            guard let pollerKey = Self.agentMessageTrimmed(params["poller_key"]),
                  let deferred = store.deferredMessages(
                      recipientSurfaceId: surfaceId,
                      pollerKey: pollerKey,
                      limit: .max
                  ) else {
                return .ok(["status": "superseded", "messages": [], "text": ""])
            }
            messages = deferred.messages
            leaseID = deferred.id.isEmpty ? nil : deferred.id
        } else {
            messages = store.claimQueued(recipientSurfaceId: surfaceId, via: via)
        }
        var payload: [String: Any] = [
            "messages": messages.map(AgentMessageCenter.payload),
            "text": messages.agentPromptText,
        ]
        if let leaseID { payload["lease_id"] = leaseID }
        return .ok(payload)
    }

    private nonisolated func agentMessageAck(params: [String: Any]) -> V2CallResult {
        guard let surfaceId = Self.agentMessageSurfaceUUID(params["surface_id"]),
              let leaseID = Self.agentMessageTrimmed(params["lease_id"]),
              let pollerKey = Self.agentMessageTrimmed(params["poller_key"]) else {
            return Self.agentMessageMissingSurface()
        }
        let via = Self.agentMessageTrimmed(params["via"]) ?? "claude.wake"
        let messages = AgentMessageCenter.store.acknowledgeDeferredLease(
            id: leaseID,
            recipientSurfaceId: surfaceId,
            pollerKey: pollerKey,
            via: via
        )
        return .ok([
            "status": "acknowledged",
            "messages": messages.map(AgentMessageCenter.payload),
            "text": messages.agentPromptText,
        ])
    }

    private nonisolated func agentMessageMarkRead(params: [String: Any]) -> V2CallResult {
        let store = AgentMessageCenter.store
        var ids = (params["ids"] as? [String]) ?? []
        if let id = Self.agentMessageTrimmed(params["id"]) {
            ids.append(id)
        }
        let surfaceRead: [AgentMessage]
        if let surfaceId = Self.agentMessageSurfaceUUID(params["surface_id"]) {
            surfaceRead = store.markDeliveredRead(recipientSurfaceId: surfaceId)
        } else {
            surfaceRead = []
        }
        let read = store.markRead(ids: ids) + surfaceRead
        return .ok(["read": read.map(\.id)])
    }

    /// The Claude wake hook's check, answered at once. The hook opens a new
    /// connection for each check, so an idle agent never holds one of the
    /// socket's connection slots. `register` makes `poller_key` the surface's
    /// owner; an older hook for the same surface then gets `superseded` and
    /// exits. Nothing is claimed here: the hook claims right before handing
    /// the messages to Claude, so a hook that died can't swallow them.
    /// `held` is true while the surface is waiting on a human (a question,
    /// permission or plan prompt is open), so a message never lands on top of
    /// an open dialog.
    private nonisolated func agentMessagePoll(params: [String: Any]) async -> V2CallResult {
        guard let surfaceId = Self.agentMessageSurfaceUUID(params["surface_id"]),
              let surfaceUUID = UUID(uuidString: surfaceId) else {
            return Self.agentMessageMissingSurface()
        }
        let pollerKey = Self.agentMessageTrimmed(params["poller_key"]) ?? surfaceId
        let register = params["register"] as? Bool == true
        let store = AgentMessageCenter.store
        switch store.poll(recipientSurfaceId: surfaceId, pollerKey: pollerKey, register: register) {
        case .superseded:
            return .ok(["status": "superseded"])
        case .current(let queued):
            if register, params["mark_delivered_read"] as? Bool == true {
                store.markDeliveredRead(recipientSurfaceId: surfaceId)
            }
            let held: Bool
            if queued > 0 {
                do {
                    held = try await v2MainAsync { self.agentMessageDeliveryHeld(surfaceId: surfaceUUID) }
                } catch {
                    return Self.agentMessageMainHopFailure(error)
                }
            } else {
                held = false
            }
            return .ok(["status": "current", "queued": queued, "held": held])
        }
    }

    nonisolated static func agentMessageMainHopFailure(_ error: Error) -> V2CallResult {
        if let timeout = error as? SocketMainActorHopTimeout {
            let message = timeout.retryable
                ? String(
                    localized: "socket.mainActorHop.timeout.notRun",
                    defaultValue: "cmux did not respond within 10 seconds, so the command was not run. Retry in a moment."
                )
                : String(
                    localized: "socket.mainActorHop.timeout.mayHaveRun",
                    defaultValue: "cmux did not respond within 10 seconds after the command started, so its result is unknown. Check the effect before retrying."
                )
            return .err(
                code: "timeout",
                message: message,
                data: [
                    "retryable": timeout.retryable,
                    "deadline_ms": Self.socketMainActorHopDeadlineMilliseconds,
                    "stage": "main_actor",
                ]
            )
        }
        if error is CancellationError {
            return .err(
                code: "cancelled",
                message: String(localized: "socket.request.cancelled", defaultValue: "Request was cancelled"),
                data: nil
            )
        }
        return .err(code: "internal_error", message: String(describing: error), data: nil)
    }

    // MARK: - Resolution

    /// Resolves a surface or workspace id or ref, or a workspace title (exact,
    /// case-insensitive, then a unique prefix). A workspace resolves to the
    /// surface running its agent: the focused agent surface, then any agent
    /// surface, then the focused terminal.
    @MainActor
    func agentMessageResolveRecipient(
        _ target: String,
        allowedSurfaceIDs: Set<UUID>? = nil
    ) -> AgentMessageRecipient? {
        guard let app = AppDelegate.shared else { return nil }
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let managers = app.listMainWindowSummaries().compactMap { app.tabManagerFor(windowId: $0.windowId) }
        let workspaces = managers.flatMap(\.tabs)

        if let id = UUID(uuidString: trimmed) ?? v2ResolveHandleRef(trimmed) {
            if let workspace = workspaces.first(where: { $0.id == id }) {
                return agentMessageRecipient(in: workspace, allowedSurfaceIDs: allowedSurfaceIDs)
            }
            if let workspace = workspaces.first(where: { $0.panels[id] != nil }) {
                guard allowedSurfaceIDs == nil || allowedSurfaceIDs?.contains(id) == true else {
                    return nil
                }
                return agentMessageRecipient(workspace: workspace, surfaceId: id)
            }
            return nil
        }

        let lowered = trimmed.lowercased()
        let titled = workspaces.filter { $0.title.lowercased() == lowered }
        if titled.count == 1, let workspace = titled.first {
            return agentMessageRecipient(in: workspace, allowedSurfaceIDs: allowedSurfaceIDs)
        }
        guard titled.isEmpty else { return nil }
        let prefixed = workspaces.filter { $0.title.lowercased().hasPrefix(lowered) }
        guard prefixed.count == 1, let workspace = prefixed.first else { return nil }
        return agentMessageRecipient(in: workspace, allowedSurfaceIDs: allowedSurfaceIDs)
    }

    @MainActor
    private func agentMessageRecipient(
        in workspace: Workspace,
        allowedSurfaceIDs: Set<UUID>? = nil
    ) -> AgentMessageRecipient? {
        let terminalIds = workspace.panels.compactMap { (id, panel) -> UUID? in
            guard panel is TerminalPanel,
                  allowedSurfaceIDs == nil || allowedSurfaceIDs?.contains(id) == true else {
                return nil
            }
            return id
        }
        let agentIds = terminalIds.filter { workspace.agentLifecycleStatesByPanelId[$0]?.isEmpty == false }
        let focused = workspace.focusedPanelId
        let chosen: UUID?
        if let focused, agentIds.contains(focused) {
            chosen = focused
        } else if let firstAgent = agentIds.sorted(by: { $0.uuidString < $1.uuidString }).first {
            chosen = firstAgent
        } else if let focused, terminalIds.contains(focused) {
            chosen = focused
        } else {
            chosen = terminalIds.sorted(by: { $0.uuidString < $1.uuidString }).first
        }
        guard let chosen else { return nil }
        return agentMessageRecipient(workspace: workspace, surfaceId: chosen)
    }

    @MainActor
    private func agentMessageRecipient(workspace: Workspace, surfaceId: UUID) -> AgentMessageRecipient {
        AgentMessageRecipient(
            surfaceId: surfaceId,
            workspaceId: workspace.id,
            surfaceRef: v2EnsureHandleRef(kind: .surface, uuid: surfaceId),
            workspaceRef: v2EnsureHandleRef(kind: .workspace, uuid: workspace.id),
            workspaceTitle: workspace.title,
            hasAgent: workspace.agentLifecycleStatesByPanelId[surfaceId]?.isEmpty == false
        )
    }

    /// Title of the sender's workspace, used when the sender gives no name.
    @MainActor
    private func agentMessageWorkspaceTitle(surfaceId: String?, workspaceId: String?) -> String? {
        guard let app = AppDelegate.shared else { return nil }
        let workspace: Workspace?
        if let surfaceId, let uuid = UUID(uuidString: surfaceId) {
            workspace = app.workspaceContainingPanel(
                panelId: uuid,
                preferredWorkspaceId: workspaceId.flatMap(UUID.init(uuidString:))
            )?.workspace
        } else if let workspaceId, let uuid = UUID(uuidString: workspaceId) {
            workspace = app.tabManagerFor(tabId: uuid)?.workspacesById[uuid]
        } else {
            workspace = nil
        }
        guard let title = workspace?.title.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        return String(title.prefix(AgentMessageDraft.maximumSenderNameLength))
    }

    /// True while the surface's agent is waiting on a human.
    @MainActor
    func agentMessageDeliveryHeld(surfaceId: UUID) -> Bool {
        guard let app = AppDelegate.shared,
              let located = app.workspaceContainingPanel(panelId: surfaceId) else { return false }
        return located.workspace.agentHibernationLifecycleState(panelId: surfaceId, fallback: nil) == .needsInput
    }

    // MARK: - Helpers

    nonisolated static func agentMessageTrimmed(_ raw: Any?) -> String? {
        guard let string = raw as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Hooks pass the surface UUID from `CMUX_SURFACE_ID`; stored ids use the
    /// canonical uppercase form.
    nonisolated static func agentMessageSurfaceUUID(_ raw: Any?) -> String? {
        guard let string = agentMessageTrimmed(raw), let uuid = UUID(uuidString: string) else { return nil }
        return uuid.uuidString
    }

    private nonisolated static func agentMessageMissingSurface() -> V2CallResult {
        .err(
            code: "invalid_params",
            message: String(
                localized: "socket.agentMessage.error.missingSurface",
                defaultValue: "A surface_id UUID is required."
            ),
            data: nil
        )
    }

    private nonisolated static func agentMessageUnknownIdMessage(_ id: String) -> String {
        String(
            format: String(
                localized: "socket.agentMessage.error.unknownMessage",
                defaultValue: "No message with id %@."
            ),
            id
        )
    }

    private nonisolated static func agentMessageValidationMessage(_ error: AgentMessageValidationError) -> String {
        switch error {
        case .emptyBody:
            return String(localized: "socket.agentMessage.error.emptyBody", defaultValue: "The message is empty.")
        case .bodyTooLarge:
            return String(
                localized: "socket.agentMessage.error.bodyTooLarge",
                defaultValue: "The message is too long. The limit is 32 KiB."
            )
        case .controlCharacterInBody:
            return String(
                localized: "socket.agentMessage.error.controlCharacter",
                defaultValue: "The message contains control characters. Only text, newlines and tabs are allowed."
            )
        case .invalidSenderName:
            return String(
                localized: "socket.agentMessage.error.invalidSender",
                defaultValue: "The sender name must be one line of at most 64 characters."
            )
        case .missingRecipient:
            return String(
                localized: "socket.agentMessage.error.targetNotFound",
                defaultValue: "No workspace or surface matches that target."
            )
        }
    }
}
