import Foundation

// Panel ownership of agent PID keys: which pane owns each reported key, and
// how a bare shared key (claude-style hooks report one key per agent type for
// the whole workspace) moves between panes without erasing a sibling pane's
// live agent row. Cleanup of the maps written here stays with the callers in
// `Workspace+PanelLifecycle.swift` (`clearAgentPID`, the liveness sweeps, and
// `discardClosedPanelLifecycleState`).
extension Workspace {
    func removeAgentPIDOwnership(key: String) {
        if let previousPanelId = agentPIDPanelIdsByKey[key] {
            agentPIDKeysByPanelId[previousPanelId]?.remove(key)
            if agentPIDKeysByPanelId[previousPanelId]?.isEmpty == true {
                agentPIDKeysByPanelId.removeValue(forKey: previousPanelId)
            }
            agentPIDPanelIdsByKey.removeValue(forKey: key)
        }
    }

    func recordAgentPIDOwnership(key: String, panelId: UUID) {
        if let previousPanelId = agentPIDPanelIdsByKey[key], previousPanelId != panelId {
            preserveDisplacedBareKeyRuntime(key: key, displacedPanelId: previousPanelId)
            removeAgentPIDOwnership(key: key)
        }
        if isStructuredAgentHookPIDKey(key) {
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            let stalePanelKeys = agentPIDKeysByPanelId[panelId]?.filter {
                $0 != key && isStructuredAgentHookPIDKey($0)
            } ?? []
            for staleKey in stalePanelKeys {
                // A stale key for the SAME agent type is a key-shape change
                // (bare key returning to a pane that holds a synthesized
                // displacement key): keep the pane's status entry. A different
                // agent type is a real replacement: clear its status too.
                let sameAgent = agentStatusKey(forAgentPIDKey: staleKey) == statusKey
                _ = clearAgentPID(key: staleKey, panelId: panelId, clearStatus: !sameAgent, refreshPorts: false)
            }
        }
        agentPIDPanelIdsByKey[key] = panelId
        agentPIDKeysByPanelId[panelId, default: []].insert(key)
    }

    /// Claude-style dedicated hooks share ONE bare PID key per agent type
    /// across every pane of a workspace, so a report from pane B displaces
    /// pane A's ownership even though A still hosts its own live agent.
    /// Re-key A's record to a synthesized panel-scoped key instead of dropping
    /// its presence: the pid and start-time identity move with it, so the
    /// liveness sweep still owns cleanup, and A keeps its sidebar row.
    private func preserveDisplacedBareKeyRuntime(key: String, displacedPanelId: UUID) {
        guard isStructuredAgentHookPIDKey(key), !key.contains(".") else { return }
        guard panels[displacedPanelId] != nil, let pid = agentPIDs[key] else { return }
        let synthesizedKey = Self.synthesizedDisplacedPIDKey(statusKey: key, panelId: displacedPanelId)
        agentPIDs[synthesizedKey] = pid
        agentPIDProcessIdentitiesByKey[synthesizedKey] = agentPIDProcessIdentitiesByKey[key]
        agentPIDPanelIdsByKey[synthesizedKey] = displacedPanelId
        agentPIDKeysByPanelId[displacedPanelId, default: []].insert(synthesizedKey)
    }

    static func synthesizedDisplacedPIDKey(statusKey: String, panelId: UUID) -> String {
        "\(statusKey).pane-\(panelId.uuidString)"
    }

    /// Workspace-scoped removal of every runtime tracked for a status key:
    /// the bare shared key, every synthesized displacement key, and every
    /// pane's lifecycle for the key. This backs the `clear_status <key>`
    /// contract ("removes the key from the whole workspace"). The liveness
    /// sweep must NOT use this: it judges each pid key's process separately,
    /// and a dead bare-key owner does not imply displaced siblings are dead.
    func clearAgentRuntimes(forStatusKey statusKey: String, refreshPorts: Bool = true) {
        var keysToClear = Set<String>()
        for key in agentPIDs.keys where agentStatusKey(forAgentPIDKey: key) == statusKey {
            keysToClear.insert(key)
        }
        for key in agentPIDPanelIdsByKey.keys where agentStatusKey(forAgentPIDKey: key) == statusKey {
            keysToClear.insert(key)
        }
        var didChange = false
        for key in keysToClear {
            if clearAgentPID(key: key, clearStatus: false, refreshPorts: false) {
                didChange = true
            }
        }
        if clearAgentLifecycle(key: statusKey) {
            didChange = true
        }
        if didChange, refreshPorts {
            refreshTrackedAgentPorts()
        }
    }

    @discardableResult
    func clearOtherStructuredAgentRuntimes(onPanel panelId: UUID, keeping retainedKey: String) -> Bool {
        guard isStructuredAgentHookPIDKey(retainedKey) else { return false }
        let retainedStatusKey = agentStatusKey(forAgentPIDKey: retainedKey)
        let staleKeys = agentPIDKeysByPanelId[panelId] ?? []
        var didChange = false
        for staleKey in staleKeys where staleKey != retainedKey && isStructuredAgentHookPIDKey(staleKey) {
            // A stale key for the SAME agent type is a key-shape change (bare
            // key returning to a pane holding a synthesized displacement key):
            // keep the pane's status entry. A different agent type is a real
            // replacement: clear its status too.
            let sameAgent = agentStatusKey(forAgentPIDKey: staleKey) == retainedStatusKey
            if clearAgentPID(key: staleKey, panelId: panelId, clearStatus: !sameAgent, refreshPorts: false) {
                didChange = true
            }
        }
        // A pane can hold a panel-scoped structured status with NO recorded
        // pid (`set_status --panel` without `--pid`), which the loop above
        // never sees. A different structured agent replacing it on this pane
        // must drop that entry and its lifecycle, or the row keeps showing
        // the dead agent's text (nil-entry candidates lose to any entry in
        // sidebarAgentStatusRows' comparator). Mirror pane close for the
        // workspace-level slot: drop it when this pane was its last owner.
        for statusKey in Set((statusEntriesByPanelId[panelId] ?? [:]).keys)
        where statusKey != retainedStatusKey && Self.structuredAgentHookStatusKeys.contains(statusKey) {
            if clearPanelStatusEntry(statusKey: statusKey, panelId: panelId) {
                didChange = true
            }
            if clearAgentLifecycle(key: statusKey, panelId: panelId) {
                didChange = true
            }
            if panelsOwningAgentStatusKey(statusKey).isEmpty,
               !hasAgentRuntime(forStatusKey: statusKey),
               statusEntries.removeValue(forKey: statusKey) != nil {
                didChange = true
            }
        }
        return didChange
    }
}
