import AppKit
import CMUXAgentLaunch
import CmuxSettings
import CmuxSidebar
import Foundation

// MARK: - In-app attention surfacing

extension FeedCoordinator {
    /// Hook events that warrant pulling the user's attention to the owning
    /// workspace: a blocking Feed decision or an agent-owned approval wait.
    /// Keeping this as one predicate (rather than branching per event at each
    /// call site) makes the attention surface uniform across every event type
    /// and agent routed through `feed.push`.
    static func isNeedsInputAttentionEvent(_ hookEventName: WorkstreamEvent.HookEventName) -> Bool {
        isBlockingDecisionEvent(hookEventName) || hookEventName == .approvalWait
    }

    /// Blocking-decision events that expect a Feed reply.
    static func isBlockingDecisionEvent(_ hookEventName: WorkstreamEvent.HookEventName) -> Bool {
        switch hookEventName {
        case .permissionRequest, .exitPlanMode, .askUserQuestion:
            return true
        default:
            return false
        }
    }

    /// Maps a feed `source` to the agent-lifecycle status key the sidebar reads.
    private static let lifecycleStatusKeyOverrides = [
        "claude": "claude_code",
    ]

    static func lifecycleStatusKey(forSource source: String) -> String {
        lifecycleStatusKeyOverrides[source] ?? source
    }

    /// Identifies the sidebar slot an attention overlay lights up.
    struct AttentionTarget: Hashable, Sendable {
        let workspaceId: UUID
        let panelId: UUID?
        let statusKey: String
    }

    /// The localized "Needs input" sidebar status the overlay sets.
    static var needsInputStatusValue: String {
        String(localized: "feed.status.needsInput", defaultValue: "Needs input")
    }

    /// Surfaces in-app attention for a feed decision or agent-owned wait.
    @MainActor
    func surfaceNeedsInputAttention(
        event: WorkstreamEvent,
        resolved: (workspaceId: UUID, surfaceId: UUID?)?
    ) -> AttentionTarget? {
        guard Self.isNeedsInputAttentionEvent(event.hookEventName) else { return nil }

        #if DEBUG
        if let observer = FeedCoordinatorTestHooks.attentionSurfaceObserver {
            observer(event)
            return nil
        }
        #endif

        guard let resolved else {
            #if DEBUG
            cmuxDebugLog(
                "feed.attention.skip reason=unresolved-target session=\(event.sessionId) request=\(event.requestId ?? "nil") hook=\(event.hookEventName.rawValue) source=\(event.source) workspace=\(event.workspaceId ?? "nil") receivedAt=\(event.receivedAt.timeIntervalSince1970)"
            )
            #endif
            return nil
        }

        guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: resolved.workspaceId),
              let tab = tabManager.tabs.first(where: { $0.id == resolved.workspaceId })
        else {
            #if DEBUG
            cmuxDebugLog(
                "feed.attention.skip reason=missing-workspace session=\(event.sessionId) request=\(event.requestId ?? "nil") hook=\(event.hookEventName.rawValue) source=\(event.source) workspace=\(resolved.workspaceId.uuidString) receivedAt=\(event.receivedAt.timeIntervalSince1970)"
            )
            #endif
            return nil
        }

        let panelId = Self.resolvePanelId(surfaceId: resolved.surfaceId, tab: tab) ?? tab.focusedPanelId
        let statusKey = Self.lifecycleStatusKey(forSource: event.source)
        let target = AttentionTarget(
            workspaceId: resolved.workspaceId,
            panelId: panelId,
            statusKey: statusKey
        )
        let attentionState = pendingAttentionStates[target] ?? AttentionOverlayState(workspace: tab)
        attentionState.workspace = tab
        attentionState.count += 1
        pendingAttentionStates[target] = attentionState

        tab.setAgentLifecycle(key: statusKey, panelId: panelId, lifecycle: .needsInput)
        tab.statusEntries[statusKey] = SidebarStatusEntry(
            key: statusKey,
            value: Self.needsInputStatusValue,
            icon: "bell.fill",
            color: "#4C8DFF",
            timestamp: Date()
        )

        if UserDefaultsSettingsClient(defaults: .standard).value(for: SettingCatalog().app.reorderOnNotification) {
            tabManager.moveTabToTopForNotification(resolved.workspaceId)
        }
        NSApp.requestUserAttention(.informationalRequest)

        return target
    }

    /// Concludes a needs-input attention overlay without clearing newer agent state.
    @MainActor
    func concludeNeedsInputAttention(_ target: AttentionTarget) {
        guard let attentionState = pendingAttentionStates[target] else { return }
        if attentionState.count > 1 {
            attentionState.count -= 1
            return
        }
        pendingAttentionStates.removeValue(forKey: target)
        let tab = attentionState.workspace

        if let panelId = target.panelId,
           tab.agentLifecycleStatesByPanelId[panelId]?[target.statusKey] == .needsInput {
            tab.setAgentLifecycle(key: target.statusKey, panelId: panelId, lifecycle: .running)
        }

        let anotherPanelStillPending = pendingAttentionStates.keys.contains {
            $0.workspaceId == target.workspaceId && $0.statusKey == target.statusKey
        }
        if !anotherPanelStillPending,
           tab.statusEntries[target.statusKey]?.value == Self.needsInputStatusValue {
            tab.statusEntries.removeValue(forKey: target.statusKey)
        }
    }

    @MainActor
    func concludeApprovalWaitAttention(forWorkstreamId workstreamId: String) {
        guard let target = pendingApprovalWaitAttentionTargets.removeValue(forKey: workstreamId) else {
            return
        }
        concludeNeedsInputAttention(target)
    }

    /// Resolves the `(workspace, surface)` an attention overlay should target.
    static func resolveAttentionTarget(
        event: WorkstreamEvent
    ) -> (workspaceId: UUID, surfaceId: UUID?)? {
        let sessionMatch: (workspaceId: UUID, surfaceId: UUID?)? = {
            guard let parsed = FeedJumpResolver.parse(event.sessionId),
                  let resolved = FeedJumpResolver.lookup(agent: parsed.agent, sessionId: parsed.sessionId),
                  let workspaceId = UUID(uuidString: resolved.workspaceId)
            else { return nil }
            return (workspaceId, UUID(uuidString: resolved.surfaceId))
        }()

        let eventWorkspaceId = event.workspaceId.flatMap {
            UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard let workspaceId = eventWorkspaceId ?? sessionMatch?.workspaceId else {
            return nil
        }
        let surfaceId = (sessionMatch?.workspaceId == workspaceId) ? sessionMatch?.surfaceId : nil
        return (workspaceId, surfaceId)
    }

    @MainActor
    private static func resolvePanelId(surfaceId: UUID?, tab: Workspace) -> UUID? {
        guard let surfaceId else { return nil }
        if tab.panels[surfaceId] != nil { return surfaceId }
        return tab.panelIdFromSurfaceId(TabID(uuid: surfaceId))
    }
}
