import CMUXAgentLaunch
import CmuxAgentJournal
import CmuxFoundation
import CmuxSettings
import Foundation

extension FeedCoordinator {
    /// The accepted Feed decision fans out through the existing store for history,
    /// unread, pane flash, reorder, and push. Feed retains its actionable native
    /// banner renderer; both lanes consume the same policy effects exactly once.
    @MainActor
    func acceptSemanticFeedNotification(
        event: WorkstreamEvent, requestId: String, title: String, subtitle: String,
        body: String, effects: TerminalNotificationPolicyEffects,
        soundContext: NotificationSoundOverrideContext?
    ) async -> Bool {
        let settings = NotificationsCatalogSection()
        guard settings.agentPermissionPrompt.value(in: .standard) else { return false }
        guard let resolved = await resolveAttentionTarget(event: event),
              let surfaceID = resolved.surfaceId,
              let target = AppDelegate.shared?.agentNotificationDeliveryTarget(
                claimedTabId: resolved.ownerId, surfaceId: surfaceID),
              let liveSurfaceID = target.surfaceId else { return false }
        let input = AgentFeedSemanticInput(event: event,
            agentKey: Self.lifecycleStatusKey(forSource: event.source),
            notification: AgentJournalNotification(title: title, subtitle: subtitle,
                body: body, category: "needs-permission", correlationKey: requestId),
            requestID: requestId, workspaceID: target.tabId, surfaceID: liveSurfaceID)
        guard await notificationJournal.admitFeedNotification(input),
              isAwaitingDecision(requestId: requestId) else { return false }
        var storeEffects = effects
        // The actionable banner below owns these three effects. Disabling them
        // here prevents a second banner/sound/command from the history lane.
        storeEffects.desktop = false
        storeEffects.sound = false
        storeEffects.command = false
        let request = TerminalNotificationPolicyRequest(tabId: target.tabId,
            surfaceId: liveSurfaceID, retargetsToLiveSurfaceOwner: true,
            correlationKey: requestId, title: title, subtitle: subtitle, body: body,
            cwd: event.cwd, isAppFocused: AppFocusState.isAppFocused(), isFocusedPanel: false,
            agent: TerminalNotificationPolicyAgentContext(kind: event.source,
                category: "needs-permission", pending: false, isSubagent: false, sessionId: input.sessionID), soundContext: soundContext)
        guard AgentJournalLifecycleCenter.notificationRequestIsCurrent(request) else { return false }
        _ = TerminalNotificationStore.shared.applyNotification(request: request, effects: storeEffects,
            now: Date(), cooldownReservation: nil, scrollPosition: nil, clickAction: nil,
            notificationID: UUID())
        return true
    }
    @MainActor
    func clearSemanticFeedNotification(requestId: String) {
        let store = TerminalNotificationStore.shared
        for notification in store.notifications where notification.correlationKey == requestId {
            guard let surfaceID = notification.surfaceId else { continue }
            store.clearNotifications(forTabId: notification.tabId, surfaceId: surfaceID,
                correlationKey: requestId)
        }
    }

    /// Feed frames are normalized on the existing journal worker, not the UI actor.
    @MainActor
    func observeSemanticLifecycle(_ event: WorkstreamEvent) {
        retireDecisionsAnsweredInTerminal(after: event)
        switch event.hookEventName {
        case .sessionStart, .sessionEnd, .userPromptSubmit, .subagentStart, .subagentStop, .postToolUse:
            notificationJournal.observeFeed(AgentFeedSemanticInput(event: event,
                agentKey: Self.lifecycleStatusKey(forSource: event.source)))
        default:
            break
        }
    }

    /// Ends one Feed decision the agent no longer waits on: the hook returns
    /// neutral output, the card expires, and its "Needs input" overlay clears.
    /// - Returns: `false` when a reply or timeout already ended the request.
    @discardableResult
    func invalidateSemanticRequest(requestId: String, source: String, sessionId: String) -> Bool {
        guard let (reply, itemID) = waiterRegistry.invalidate(requestID: requestId, source: source, sessionID: sessionId) else {
            return false
        }
        cancelNotification(requestId: requestId)
        concludeAttentionOnMain(reply.target)
        expireTimedOutItem(itemID)
        waiterRegistry.cleanupStored(requestID: requestId, groupID: reply.groupID)
        return true
    }

    /// Agents whose own terminal prompt stays live while the blocking hook
    /// waits on the Feed. Claude shows its permission prompt when the
    /// `PermissionRequest` hook starts and lets that hook run on after the
    /// user answers in the terminal (checked on 2.1.283), so the Feed never
    /// hears the answer.
    private static let sourcesAnsweredInTerminal: Set<String> = ["claude"]

    /// Claude tools that never run beside another tool. While one of these
    /// waits on its prompt, the same agent starts no other tool, so its next
    /// tool call proves the prompt was answered. Concurrency-safe tools
    /// (Read, WebFetch, MCP reads) can wait while a sibling runs.
    private static let serialClaudeTools: Set<String> = [
        "Bash", "Edit", "Write", "MultiEdit", "NotebookEdit", "AskUserQuestion", "ExitPlanMode",
    ]

    /// Retires Feed decisions the user already answered in the agent's terminal,
    /// instead of leaving "Needs input" beside "Running" until the hook's deadline.
    ///
    /// A later tool call from the same agent (the main agent, or one subagent by
    /// `agent_id`) retires a serial tool's request; the end of that agent's turn
    /// or of the session retires any request. The decision hook waits for
    /// earlier queued hooks before it pushes and same-session Feed ingress is
    /// ordered, so the call that raised a request is normally accepted before it;
    /// ``couldHaveRaised(_:by:)`` covers the rare late arrival.
    @MainActor
    private func retireDecisionsAnsweredInTerminal(after event: WorkstreamEvent) {
        guard Self.sourcesAnsweredInTerminal.contains(event.source) else { return }
        let isToolCall: Bool
        switch event.hookEventName {
        case .preToolUse: isToolCall = true
        case .userPromptSubmit, .stop, .subagentStop, .sessionEnd: isToolCall = false
        default: return
        }
        let pending = waiterRegistry.acceptedPendingRequests(inSessionOf: event)
        guard !pending.isEmpty else { return }
        let agentID = Self.subagentID(of: event)
        for request in pending {
            guard event.hookEventName == .sessionEnd || Self.subagentID(of: request.event) == agentID else { continue }
            if isToolCall {
                guard request.event.toolName.map({ Self.serialClaudeTools.contains($0) }) == true,
                      !Self.couldHaveRaised(request.event, by: event) else { continue }
            }
            let input = AgentFeedSemanticInput(event: request.event,
                agentKey: Self.lifecycleStatusKey(forSource: request.event.source),
                requestID: request.requestID, resolvesRequest: true)
            guard invalidateSemanticRequest(requestId: request.requestID,
                source: request.event.source, sessionId: input.sessionID) else { continue }
            clearSemanticFeedNotification(requestId: request.requestID)
            // A tool call means the turn is running again. Turn and session
            // ends journal their own boundary, which already retires attention.
            if isToolCall { notificationJournal.observeFeed(input) }
        }
    }

    /// Whether `event` could be the tool call that raised `request`. Tool
    /// telemetry carries whitespace-collapsed, truncated input fields, so each
    /// string it kept only has to agree with the request up to its "…".
    private static func couldHaveRaised(_ request: WorkstreamEvent, by event: WorkstreamEvent) -> Bool {
        guard event.hookEventName == .preToolUse, event.toolName == request.toolName else { return false }
        let asked = jsonObject(request.toolInputJSON)
        for (key, value) in jsonObject(event.toolInputJSON) {
            guard let seen = value as? String else { continue }
            guard let full = asked[key] as? String else { return false }
            let text = full.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let agrees = seen.hasSuffix("…") ? text.hasPrefix(String(seen.dropLast()))
                : seen.hasPrefix("…") ? text.hasSuffix(String(seen.dropFirst())) : text == seen
            guard agrees else { return false }
        }
        return true
    }

    private static func subagentID(of event: WorkstreamEvent) -> String? {
        jsonObject(event.extraFieldsJSON)["agent_id"] as? String
    }

    private static func jsonObject(_ json: String?) -> [String: Any] {
        guard let data = json?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}
