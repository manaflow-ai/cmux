import Foundation

/// Orphaned agent notifications after a session restore.
///
/// Notifications are persisted across relaunch so an unseen agent result is not
/// lost. But an agent that was alive when cmux quit dies with the app without
/// firing its SessionEnd hook, so nothing ever clears its last "Completed in …"
/// notification, and the sidebar keeps showing it as the workspace's latest
/// summary on every subsequent launch. The live-session safety net
/// (`clearStaleAgentPIDs`) cannot catch it either: agent PIDs are not
/// restored, so there is no dead PID to sweep.
///
/// Restore therefore records the notifications that belonged to a local agent
/// pane, and the periodic sweep drops the ones that were read once it is clear
/// the agent did not come back to that pane. Unread ones survive until read.
extension Workspace {
    /// Whether a persisted panel was hosting a local agent session that died
    /// with the previous app process. Remote terminals are excluded: their agent
    /// can outlive the local app and keep owning its notifications.
    static func restoredPanelHostedLocalAgent(_ panelSnapshot: SessionPanelSnapshot) -> Bool {
        guard let terminal = panelSnapshot.terminal else { return false }
        guard terminal.isRemoteTerminal != true, terminal.remotePTYSessionID == nil else { return false }
        return terminal.resumeBinding != nil || terminal.agent != nil
    }

    func trackRestoredAgentNotifications(
        from snapshot: SessionWorkspaceSnapshot,
        oldToNewPanelIds: [UUID: UUID]
    ) {
        restoredAgentNotificationIdsByPanelId.removeAll(keepingCapacity: false)
        guard snapshot.remote == nil else { return }
        for panelSnapshot in snapshot.panels where Self.restoredPanelHostedLocalAgent(panelSnapshot) {
            guard let newPanelId = oldToNewPanelIds[panelSnapshot.id] else { continue }
            let ids = Set((panelSnapshot.notifications ?? []).map(\.id))
            guard !ids.isEmpty else { continue }
            restoredAgentNotificationIdsByPanelId[newPanelId] = ids
        }
#if DEBUG
        cmuxDebugLog(
            "restoredAgentNotifications.track workspace=\(id.uuidString.prefix(8)) panels=\(snapshot.panels.count) tracked=\(restoredAgentNotificationIdsByPanelId.count)"
        )
#endif
    }

    /// Removes read restored agent notifications on panes the agent never
    /// returned to. A pane that registered a new agent PID is handed back to the
    /// agent hooks, which own its notifications from then on.
    @discardableResult
    func pruneOrphanedRestoredAgentNotifications(store: TerminalNotificationStore) -> Bool {
        guard !restoredAgentNotificationIdsByPanelId.isEmpty else { return false }
        var didRemove = false
        for (panelId, trackedIds) in restoredAgentNotificationIdsByPanelId {
            let hasLiveAgent = !(agentPIDKeysByPanelId[panelId] ?? []).isEmpty
#if DEBUG
            cmuxDebugLog(
                "restoredAgentNotifications.prune workspace=\(id.uuidString.prefix(8)) panel=\(panelId.uuidString.prefix(8)) exists=\(panels[panelId] != nil ? 1 : 0) liveAgent=\(hasLiveAgent ? 1 : 0) tracked=\(trackedIds.count)"
            )
#endif
            guard panels[panelId] != nil, !hasLiveAgent else {
                restoredAgentNotificationIdsByPanelId.removeValue(forKey: panelId)
                continue
            }
            let remaining = store.notifications(forTabId: id, surfaceId: panelId)
                .filter { trackedIds.contains($0.id) }
            var stillTracked = Set<UUID>()
            for notification in remaining {
                if notification.isRead {
                    store.remove(id: notification.id)
                    didRemove = true
                } else {
                    stillTracked.insert(notification.id)
                }
            }
            if stillTracked.isEmpty {
                restoredAgentNotificationIdsByPanelId.removeValue(forKey: panelId)
            } else {
                restoredAgentNotificationIdsByPanelId[panelId] = stillTracked
            }
        }
        return didRemove
    }
}
