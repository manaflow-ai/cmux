import CmuxWorkspaces
import Foundation

/// Attach-time snapshot for one panel's agent tab branding: which agent
/// attached and what the process title was at that moment.
struct AgentTabBrandingAttachState: Equatable {
    let definitionID: String
    var processTitleAtAttach: String?
    let attachedAt: Date

    /// Shells emit their own title writes (preexec/prompt hooks) racing the
    /// launch of the agent binary; a title arriving this soon after attach is
    /// launch noise to absorb into the snapshot, not the CLI taking ownership.
    static let launchNoiseGracePeriod: TimeInterval = 3
}

/// Terminal-tab agent branding: while the hook-driven runtime maps that drive
/// the sidebar status pill report a coding agent attached to a panel, that
/// panel's tab shows the agent's brand icon (`Tab.iconAsset`) and an
/// agent-aware title resolved by `AgentTabBrandingResolver`.
extension Workspace {
    /// The coding-agent definition currently attached to `panelId`, resolved
    /// from hook-recorded PID ownership and lifecycle status keys — the same
    /// source of truth as the sidebar status pill, so the tab branding and the
    /// pill can never disagree about which agent a panel is running.
    func currentCodingAgentDefinition(panelId: UUID) -> CmuxTaskManagerCodingAgentDefinition? {
        // PID-backed keys only: hook-recorded lifecycle entries can outlive the
        // agent process (not every agent CLI reports a session end), while PID
        // records are validated against the live process and pruned by
        // `clearStaleAgentPIDs`, so the branding always detaches on exit.
        var statusKeys = Set<String>()
        for key in agentPIDKeysByPanelId[panelId] ?? [] {
            statusKeys.insert(agentStatusKey(forAgentPIDKey: key))
        }
        if !statusKeys.isEmpty,
           let definition = AgentTabBrandingResolver().definition(
               forStatusKeys: statusKeys,
               in: CmuxTaskManagerCodingAgentDefinition.builtIns
           ) {
            return definition
        }
        // Launch fast-path: hooks report only once the agent starts a session
        // (codex/grok stay silent until the first prompt), so a foreground
        // process match recorded at command start brands the tab immediately.
        if let provisionalID = provisionalAgentTabBrandingIDsByPanelId[panelId] {
            return CmuxTaskManagerCodingAgentDefinition.builtIns.first { $0.id == provisionalID }
        }
        return nil
    }

    /// Re-evaluates the launch fast-path when a panel's shell activity changes:
    /// a starting command is probed for a known agent binary, and returning to
    /// the prompt drops the provisional brand.
    func updateProvisionalAgentTabBranding(panelId: UUID, shellState: PanelShellActivityState) {
        cancelAgentTabBrandingExecWatcher(panelId: panelId)
        if shellState == .commandRunning {
            probeProvisionalAgentTabBranding(panelId: panelId, allowsReprobe: true)
        } else {
            clearProvisionalAgentTabBranding(panelId: panelId)
        }
    }

    private func probeProvisionalAgentTabBranding(panelId: UUID, allowsReprobe: Bool) {
        guard let terminalPanel = panels[panelId] as? TerminalPanel,
              let foregroundPID = terminalPanel.surface.foregroundProcessID() else {
            clearProvisionalAgentTabBranding(panelId: panelId)
            return
        }
        let definition = CmuxTopProcessSnapshot.codingAgentDefinition(foregroundPID: foregroundPID)
        if let definition {
            cancelAgentTabBrandingExecWatcher(panelId: panelId)
            if provisionalAgentTabBrandingIDsByPanelId[panelId] != definition.id {
                provisionalAgentTabBrandingIDsByPanelId[panelId] = definition.id
                refreshAgentTabBranding(panelId: panelId)
            }
            return
        }
        clearProvisionalAgentTabBranding(panelId: panelId)
        guard allowsReprobe else { return }
        watchForegroundExecForProvisionalBranding(panelId: panelId, pid: foregroundPID)
    }

    /// The shell reports command start before the launcher/wrapper exec()s the
    /// agent binary, so the immediate probe can observe the not-yet-exec'd
    /// wrapper. Watch the foreground process for its exec transition and probe
    /// again exactly then, instead of retrying on a timer.
    ///
    /// DispatchSource carve-out: kernel `NOTE_EXEC` is the event-driven signal
    /// for an exec() transition and has no async-native replacement. The
    /// source is cancelled on the next shell-activity transition and in
    /// `deinit`.
    private func watchForegroundExecForProvisionalBranding(panelId: UUID, pid: Int) {
        let source = DispatchSource.makeProcessSource(
            identifier: pid_t(pid),
            eventMask: .exec,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cancelAgentTabBrandingExecWatcher(panelId: panelId)
                self.probeProvisionalAgentTabBranding(panelId: panelId, allowsReprobe: false)
            }
        }
        agentTabBrandingExecWatchers[panelId] = source
        source.activate()
        // The exec can land between the failed probe and arming the watcher;
        // probe once more so that window cannot lose the transition.
        probeProvisionalAgentTabBranding(panelId: panelId, allowsReprobe: false)
    }

    private func cancelAgentTabBrandingExecWatcher(panelId: UUID) {
        agentTabBrandingExecWatchers.removeValue(forKey: panelId)?.cancel()
    }

    private func clearProvisionalAgentTabBranding(panelId: UUID) {
        if provisionalAgentTabBrandingIDsByPanelId.removeValue(forKey: panelId) != nil {
            cmuxDebugLog("agentTabBranding.provisional.clear panel=\(panelId.uuidString.prefix(5))")
            refreshAgentTabBranding(panelId: panelId)
        }
    }

    /// Starts observing the agent runtime maps so tab branding follows agent
    /// attach/detach. Idempotent; the task is cancelled in `deinit`.
    func startAgentTabBrandingObservation() {
        guard agentTabBrandingObservationTask == nil else { return }
        let changes = sidebarAgentRuntimeObservation.changes()
        agentTabBrandingObservationTask = Task { @MainActor [weak self] in
            for await _ in changes {
                guard let self, !Task.isCancelled else { return }
                self.refreshAgentTabBranding()
            }
        }
        refreshAgentTabBranding()
        // Panels restored mid-command never see a shell-activity transition,
        // so sweep them once for an already-running agent binary.
        for (panelId, state) in panelShellActivityStates where state == .commandRunning {
            updateProvisionalAgentTabBranding(panelId: panelId, shellState: state)
        }
    }

    /// Re-applies agent branding for every terminal panel in the workspace.
    /// Cheap when nothing changed: `updateTab` diffs before mutating.
    func refreshAgentTabBranding() {
        guard !isRemoteTmuxMirror else { return }
        agentTabBrandingAttachState = agentTabBrandingAttachState.filter {
            panels[$0.key] != nil
        }
        provisionalAgentTabBrandingIDsByPanelId = provisionalAgentTabBrandingIDsByPanelId.filter {
            panels[$0.key] != nil
        }
        for (panelId, panel) in panels where panel is TerminalPanel {
            refreshAgentTabBranding(panelId: panelId)
        }
    }

    /// Re-applies the brand icon and agent-aware title for one panel's tab,
    /// and reconciles the workspace title when the panel is focused.
    func refreshAgentTabBranding(panelId: UUID) {
        guard !isRemoteTmuxMirror,
              let panel = panels[panelId], panel is TerminalPanel,
              let tabId = surfaceIdFromPanelId(panelId),
              let existing = bonsplitController.tab(tabId) else { return }
        // Drop records of agent processes that already exited so the brand
        // detaches as soon as anything triggers a refresh for this panel.
        clearStaleAgentPIDs(panelId: panelId, refreshPorts: false)
        let definition = currentCodingAgentDefinition(panelId: panelId)
        reconcileAgentTabBrandingAttachState(panelId: panelId, definition: definition)
        let iconAsset = definition?.assetName
        let baseTitle = panelTitles[panelId] ?? panel.displayTitle
        let resolvedTitle = resolvedPanelTitle(panelId: panelId, fallback: baseTitle)
        let titleUpdate: String? = existing.title == resolvedTitle ? nil : resolvedTitle
        if titleUpdate != nil || existing.iconAsset != iconAsset {
            bonsplitController.updateTab(
                tabId,
                title: titleUpdate,
                iconAsset: .some(iconAsset)
            )
        }
        applyFocusedPanelTitle(panelId: panelId)
    }

    /// Records the process title in place when an agent attaches to a panel
    /// (or a different agent replaces it), and forgets it on detach. The
    /// snapshot is what lets the title rule distinguish "the CLI never set a
    /// title" from "the CLI took ownership of the title after launch".
    private func reconcileAgentTabBrandingAttachState(
        panelId: UUID,
        definition: CmuxTaskManagerCodingAgentDefinition?
    ) {
        guard let definition else {
            if agentTabBrandingAttachState.removeValue(forKey: panelId) != nil {
                cmuxDebugLog("agentTabBranding.detach panel=\(panelId.uuidString.prefix(5))")
            }
            return
        }
        if agentTabBrandingAttachState[panelId]?.definitionID != definition.id {
            agentTabBrandingAttachState[panelId] = AgentTabBrandingAttachState(
                definitionID: definition.id,
                processTitleAtAttach: panelTitles[panelId],
                attachedAt: Date()
            )
            cmuxDebugLog(
                "agentTabBranding.attach panel=\(panelId.uuidString.prefix(5)) agent=\(definition.id)"
            )
        }
    }

    /// Absorbs a title update that lands inside the launch-noise grace period
    /// into the attach snapshot, so a shell's own racing title write does not
    /// read as the agent CLI taking ownership of the tab title.
    func absorbAgentTabBrandingLaunchNoiseTitle(panelId: UUID, title: String) {
        guard var state = agentTabBrandingAttachState[panelId],
              Date().timeIntervalSince(state.attachedAt)
                < AgentTabBrandingAttachState.launchNoiseGracePeriod else {
            return
        }
        state.processTitleAtAttach = title
        agentTabBrandingAttachState[panelId] = state
    }
}
