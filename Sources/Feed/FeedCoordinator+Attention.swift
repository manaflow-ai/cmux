import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSettings
import CmuxSidebar
import Foundation

// MARK: - In-app attention surfacing

extension FeedCoordinator {
    /// The blocking-decision hook events that warrant pulling the user's
    /// attention to the owning workspace: a tool permission, a plan
    /// approval, or a question. Keeping this as one predicate (rather than
    /// branching per event at each call site) is what makes the attention
    /// surface uniform across every event type and agent routed through
    /// `feed.push` — a new blocking event type only has to be added here.
    static func isBlockingDecisionEvent(_ hookEventName: WorkstreamEvent.HookEventName) -> Bool {
        switch hookEventName {
        case .permissionRequest, .exitPlanMode, .askUserQuestion:
            return true
        default:
            return false
        }
    }

    /// Maps a feed `source` (agent id) to the agent-lifecycle status key the
    /// sidebar reads. Claude reports under `claude_code`; every other agent
    /// keys its status by its own source name. Returning the agent's own key
    /// is what lets the existing per-agent resume hooks (e.g. Claude's
    /// `pre-tool-use`) clear the needs-input badge once the agent continues.
    private static let lifecycleStatusKeyOverrides = [
        "claude": "claude_code",
    ]

    static func lifecycleStatusKey(forSource source: String) -> String {
        lifecycleStatusKeyOverrides[source] ?? source
    }

    /// Identifies the sidebar slot an attention overlay lights up. Overlays
    /// are refcounted by this key so overlapping blocking decisions on the
    /// same agent/panel don't clear each other's needs-input badge.
    struct AttentionTarget: Hashable, Sendable {
        let workspaceId: UUID
        let panelId: UUID?
        let statusKey: String
    }

    /// The localized "Needs input" sidebar status the overlay sets. Exposed so
    /// ``concludeBlockingDecisionAttention(_:)`` can confirm it's still the
    /// value we wrote before clearing it (rather than one an agent hook
    /// replaced in the meantime).
    static var needsInputStatusValue: String {
        String(localized: "feed.status.needsInput", defaultValue: "Needs input")
    }

    /// Surfaces in-app attention for a blocking feed decision: flips the
    /// owning workspace's agent lifecycle to `.needsInput`, sets the
    /// "Needs input" sidebar status, elevates the workspace when
    /// *Reorder on Notification* is enabled, and rings the bell.
    ///
    /// This is the convergence point the PreToolUse→PermissionRequest
    /// migration left behind: the `feed.push` bridge ingested the card and
    /// (when inactive) posted a banner, but never drove the same in-app
    /// attention path the `cmux hooks <agent> notification` hook uses. Doing
    /// it here — once, for every blocking decision — keeps a new event type
    /// from silently swallowing.
    ///
    /// The overlay is cleared by ``concludeBlockingDecisionAttention(_:)``
    /// when the decision resolves or times out. Clearing is refcounted per
    /// ``AttentionTarget`` so overlapping decisions on the same panel keep the
    /// badge lit until the last one concludes.
    ///
    /// - Parameter resolved: the target resolved off the main actor before UI
    ///   mutation, since hook-session lookup may read from disk.
    /// - Returns: the target to conclude once the decision ends, or `nil` if
    ///   nothing was surfaced (no resolvable workspace).
    @MainActor
    func surfaceBlockingDecisionAttention(
        event: WorkstreamEvent,
        resolved: (workspaceId: UUID, surfaceId: UUID?)?
    ) -> AttentionTarget? {
        guard Self.isBlockingDecisionEvent(event.hookEventName) else { return nil }

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

        // Needs-input lifecycle drives the sidebar badge + hibernation state.
        tab.setAgentLifecycle(key: statusKey, panelId: panelId, lifecycle: .needsInput)
        tab.statusEntries[statusKey] = SidebarStatusEntry(
            key: statusKey,
            value: Self.needsInputStatusValue,
            icon: "bell.fill",
            color: "#4C8DFF",
            timestamp: Date()
        )

        // Elevate the workspace so it floats to the top of the sidebar,
        // honoring the user's Reorder on Notification preference.
        if UserDefaultsSettingsClient(defaults: .standard).value(for: SettingCatalog().app.reorderOnNotification) {
            tabManager.moveTabToTopForNotification(resolved.workspaceId)
        }

        // Ring the bell (dock bounce while the app is in the background).
        NSApp.requestUserAttention(.informationalRequest)

        return target
    }

    /// Concludes a blocking decision's attention overlay. Decrements the
    /// per-target refcount and, when it reaches zero, clears the needs-input
    /// overlay — but only the parts the feed still owns: the lifecycle is set
    /// to `.running` only if it's still `.needsInput`, and the status entry is
    /// removed only if it still holds our "Needs input" value. Anything an
    /// agent hook replaced in the meantime is left untouched, so a real
    /// running/idle/needs-input update from the agent always wins.
    @MainActor
    func concludeBlockingDecisionAttention(_ target: AttentionTarget) {
        guard let attentionState = pendingAttentionStates[target] else { return }
        if attentionState.count > 1 {
            attentionState.count -= 1
            return
        }
        pendingAttentionStates.removeValue(forKey: target)
        let tab = attentionState.workspace

        // Lifecycle is per-panel, so clearing this panel's needs-input is
        // safe even if another panel still needs input.
        if let panelId = target.panelId,
           tab.agentLifecycleStatesByPanelId[panelId]?[target.statusKey] == .needsInput {
            tab.setAgentLifecycle(key: target.statusKey, panelId: panelId, lifecycle: .running)
        }

        // The status entry is workspace-level (keyed only by statusKey), so it
        // is shared across panels running the same agent. Only remove it once
        // no other panel in this workspace still has a pending decision under
        // the same key — otherwise concluding one panel would wipe another
        // panel's active "Needs input" badge.
        let anotherPanelStillPending = pendingAttentionStates.keys.contains {
            $0.workspaceId == target.workspaceId && $0.statusKey == target.statusKey
        }
        if !anotherPanelStillPending,
           tab.statusEntries[target.statusKey]?.value == Self.needsInputStatusValue {
            tab.statusEntries.removeValue(forKey: target.statusKey)
        }
    }

    /// Resolves the `(workspace, surface)` an attention overlay should target.
    /// The workspace prefers the event's live `workspace_id` (the running
    /// terminal's CMUX_WORKSPACE_ID, a raw UUID) so a stale hook-session map
    /// can't redirect attention to the wrong workspace; it falls back to the
    /// session store when the event omits a parseable id. The surface comes
    /// from the session store only when its workspace matches the resolved
    /// workspace, so a stale entry can't point the panel elsewhere.
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
        // Only trust the session store's surface if it belongs to the
        // workspace we're actually targeting.
        let surfaceId = (sessionMatch?.workspaceId == workspaceId) ? sessionMatch?.surfaceId : nil
        return (workspaceId, surfaceId)
    }

    /// Maps a surface id from the hook-session store to its owning panel id,
    /// tolerating stores that already record the panel id directly.
    @MainActor
    private static func resolvePanelId(surfaceId: UUID?, tab: Workspace) -> UUID? {
        guard let surfaceId else { return nil }
        if tab.panels[surfaceId] != nil { return surfaceId }
        return tab.panelIdFromSurfaceId(TabID(uuid: surfaceId))
    }
}
