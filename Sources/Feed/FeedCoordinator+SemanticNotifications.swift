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

    /// Agents whose own terminal prompt stays live while the blocking hook
    /// waits on the Feed. Claude shows its permission prompt when the
    /// `PermissionRequest` hook starts and lets that hook run on after the
    /// user answers in the terminal (checked on 2.1.283), so the Feed never
    /// hears the answer.
    private static let sourcesAnsweredInTerminal: Set<String> = ["claude"]

    /// Claude tools that never run beside another tool: while one waits on its
    /// prompt the agent starts nothing else, and none starts while another waits.
    private static let serialClaudeTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    /// Claude tools that may run beside read-only siblings but in practice
    /// prompt alone: a Bash that prompts is almost always a write, and a
    /// question or plan comes by itself. If a read-only sibling does retire one
    /// early, Claude's own permission notification raises Needs input again.
    private static let claudeToolsPromptingAlone: Set<String> = ["Bash", "AskUserQuestion", "ExitPlanMode"]

    /// The latest tool call per session and agent, and the requests whose own
    /// tool call has not reached the Feed yet (it normally arrives first).
    @MainActor private static var latestToolCallByAgent: [String: WorkstreamEvent] = [:]
    @MainActor private static var requestsAwaitingTheirToolCall: Set<String> = []

    /// Retires Feed decisions the user already answered in the agent's terminal,
    /// instead of leaving "Needs input" beside "Running" until the hook's deadline.
    ///
    /// Work is matched to the agent that asked (the main agent, or one subagent
    /// by `agent_id`). That agent's next tool call retires the request when
    /// either call is a serial tool or the prompt is one that comes alone; the
    /// end of its turn retires any request, and the end of the session every
    /// request. The tool call that raised a request never retires it.
    @MainActor
    private func retireDecisionsAnsweredInTerminal(after event: WorkstreamEvent) {
        guard Self.sourcesAnsweredInTerminal.contains(event.source) else { return }
        let agentKey = Self.agentKey(of: event)
        let isToolCall: Bool
        switch event.hookEventName {
        case .permissionRequest, .askUserQuestion, .exitPlanMode:
            if let requestId = event.requestId,
               Self.latestToolCallByAgent[agentKey].map({ Self.couldHaveRaised(event, by: $0) }) != true {
                Self.requestsAwaitingTheirToolCall.formIntersection(waiterRegistry.liveRequestIDs())
                Self.requestsAwaitingTheirToolCall.insert(requestId)
            }
            return
        case .preToolUse:
            isToolCall = true
            Self.latestToolCallByAgent[agentKey] = event
        case .sessionEnd:
            isToolCall = false
            Self.latestToolCallByAgent = Self.latestToolCallByAgent.filter { !$0.key.hasPrefix(Self.sessionKey(of: event)) }
        case .userPromptSubmit, .stop, .subagentStop:
            isToolCall = false
        default:
            return
        }
        for request in waiterRegistry.acceptedPendingRequests(inSessionOf: event) {
            guard event.hookEventName == .sessionEnd || Self.agentKey(of: request.event) == agentKey else { continue }
            if isToolCall {
                if Self.requestsAwaitingTheirToolCall.contains(request.requestID),
                   Self.couldHaveRaised(request.event, by: event) {
                    Self.requestsAwaitingTheirToolCall.remove(request.requestID)
                    continue
                }
                let asked = request.event.toolName ?? ""
                guard Self.serialClaudeTools.contains(asked)
                        || Self.serialClaudeTools.contains(event.toolName ?? "")
                        || Self.claudeToolsPromptingAlone.contains(asked) else { continue }
            }
            let input = AgentFeedSemanticInput(event: request.event,
                agentKey: Self.lifecycleStatusKey(forSource: request.event.source),
                requestID: request.requestID, resolvesRequest: true)
            // A reply racing this retirement journals and clears the same request; both are idempotent.
            invalidateSemanticRequest(requestId: request.requestID,
                source: request.event.source, sessionId: input.sessionID)
            Self.requestsAwaitingTheirToolCall.remove(request.requestID)
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
        guard event.toolName == request.toolName else { return false }
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

    private static func sessionKey(of event: WorkstreamEvent) -> String {
        FeedWorkstreamIdentifier.canonicalizedRawValue(agentID: event.source, rawValue: event.sessionId) + "\n"
    }

    private static func agentKey(of event: WorkstreamEvent) -> String {
        sessionKey(of: event) + ((jsonObject(event.extraFieldsJSON)["agent_id"] as? String) ?? "")
    }

    private static func jsonObject(_ json: String?) -> [String: Any] {
        guard let data = json?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}
