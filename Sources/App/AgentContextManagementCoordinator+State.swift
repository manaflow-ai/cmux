import CmuxSidebar
import CmuxWorkspaces
import Darwin
import Foundation

@MainActor
extension AgentContextManagementCoordinator {
    /// Main-actor ownership handle for a live Workspace or Dock container.
    ///
    /// Nested types do not inherit the enclosing extension's global-actor
    /// isolation under Swift 6, so the annotation is explicit: every lookup
    /// touches AppKit-backed, main-actor state on the concrete owner.
    @MainActor
    enum PanelOwner {
        case workspace(Workspace)
        case dock(DockSplitStore)

        var identity: ObjectIdentifier {
            switch self {
            case .workspace(let workspace): ObjectIdentifier(workspace)
            case .dock(let dock): ObjectIdentifier(dock)
            }
        }

        func contains(panelId: UUID) -> Bool {
            switch self {
            case .workspace(let workspace):
                workspace.panels[panelId] is TerminalPanel
            case .dock(let dock):
                dock.panels[panelId] is TerminalPanel
            }
        }

        var workspaceID: UUID {
            switch self {
            case .workspace(let workspace): workspace.id
            case .dock(let dock): dock.workspaceId
            }
        }

        func binding(panelId: UUID) -> SurfaceResumeBindingSnapshot? {
            switch self {
            case .workspace(let workspace):
                guard let binding = workspace.surfaceResumeBinding(panelId: panelId),
                      binding.isAgentHookBinding,
                      binding.hasCompleteManagedSessionIdentity else {
                    return nil
                }
                return binding
            case .dock(let dock):
                // An effective non-managed binding (for example a process-
                // detected or CLI replacement) must fence off any stale
                // managed fallback. Only consult the fallback while the
                // effective map is genuinely absent during restore handoff.
                if let effectiveBinding = dock.surfaceResumeBinding(panelId: panelId) {
                    guard effectiveBinding.isAgentHookBinding,
                          effectiveBinding.hasCompleteManagedSessionIdentity else {
                        return nil
                    }
                    return effectiveBinding
                }
                guard let managedBinding = dock.managedAgentResumeBinding(panelId: panelId),
                      managedBinding.isAgentHookBinding,
                      managedBinding.hasCompleteManagedSessionIdentity else {
                    return nil
                }
                return managedBinding
            }
        }

        func terminal(panelId: UUID) -> TerminalPanel? {
            switch self {
            case .workspace(let workspace): workspace.terminalPanel(for: panelId)
            case .dock(let dock): dock.panels[panelId] as? TerminalPanel
            }
        }

        /// Confirms that the PTY's live foreground process is the managed
        /// agent recorded for this exact panel/session generation. Shell
        /// `commandRunning` alone is deliberately insufficient because an
        /// unrelated command can reuse the same terminal after the agent exits.
        func hasVerifiedForegroundAgentProcess(
            panelId: UUID,
            provider: AgentContextProvider
        ) -> Bool {
            guard let terminal = terminal(panelId: panelId),
                  let foregroundPID = terminal.surface.foregroundProcessID(),
                  foregroundPID > 0,
                  let binding = binding(panelId: panelId),
                  binding.launchFlavor == .local else {
                return false
            }

            func keyMatchesProvider(_ key: String) -> Bool {
                let normalized = key
                    .replacingOccurrences(of: "_", with: "-")
                    .lowercased()
                switch provider {
                case .claudeCode:
                    return normalized == "claude" || normalized.hasPrefix("claude-")
                case .codex:
                    return normalized == "codex" || normalized.hasPrefix("codex-")
                }
            }

            func processMatches(
                key: String,
                pid: pid_t,
                identity: AgentPIDProcessIdentity?
            ) -> Bool {
                guard keyMatchesProvider(key),
                      Int(pid) == foregroundPID,
                      let identity,
                      identity.pid == pid,
                      let currentIdentity = Workspace.agentPIDProcessIdentity(pid: pid) else {
                    return false
                }
                return currentIdentity == identity
            }

            switch self {
            case .workspace(let workspace):
                return (workspace.agentPIDKeysByPanelId[panelId] ?? []).contains { key in
                    guard let pid = workspace.agentPIDs[key] else { return false }
                    return processMatches(
                        key: key,
                        pid: pid,
                        identity: workspace.agentPIDProcessIdentitiesByKey[key]
                    )
                }
            case .dock(let dock):
                guard let runtime = dock.agentRuntimeByPanelId[panelId] else { return false }
                return runtime.agentPIDKeys.contains { key in
                    guard let pid = runtime.agentPIDs[key] else { return false }
                    return processMatches(
                        key: key,
                        pid: pid,
                        identity: runtime.agentPIDProcessIdentities[key]
                    )
                }
            }
        }

        func setPressureStatus(_ entry: SidebarStatusEntry, key: String, panelId: UUID) {
            switch self {
            case .workspace(let workspace): workspace.statusEntries[key] = entry
            case .dock(let dock): dock.setAgentRuntimeStatusEntry(entry, key: key, panelId: panelId)
            }
        }

        func clearPressureStatus(key: String, panelId: UUID) {
            switch self {
            case .workspace(let workspace): workspace.statusEntries.removeValue(forKey: key)
            case .dock(let dock): dock.clearAgentRuntimeStatusEntry(key: key, panelId: panelId)
            }
        }

        func statusEntry(key: String, panelId: UUID) -> SidebarStatusEntry? {
            switch self {
            case .workspace(let workspace): workspace.statusEntries[key]
            case .dock(let dock): dock.agentRuntimeStatusEntry(key: key, panelId: panelId)
            }
        }

        func appendPressureLog() {
            guard case .workspace(let workspace) = self else { return }
            workspace.sidebarMetadata.appendLogEntry(
                message: String(
                    localized: "sidebar.agentContext.pressureLog",
                    defaultValue: "Context pressure detected for a managed agent."
                ),
                level: .warning,
                source: "agent-context"
            )
        }

        func shellActivity(panelId: UUID) -> PanelShellActivityState {
            terminal(panelId: panelId)?.shellActivity.state ?? .unknown
        }

        func setContextPressureMonitoringEnabled(panelId: UUID, enabled: Bool) {
            terminal(panelId: panelId)?.surface.setContextPressureMonitoringEnabled(enabled)
        }

        /// Selects the one managed provider whose structured pressure events
        /// may be parsed on this surface. A nil hint disables provider-specific
        /// parsing until an authoritative binding is published.
        func setContextPressureProvider(
            panelId: UUID,
            provider: AgentContextProvider?
        ) {
            let hint: String?
            switch provider {
            case .claudeCode: hint = "claude"
            case .codex: hint = "codex"
            case nil: hint = nil
            }
            terminal(panelId: panelId)?.surface.setContextPressureProvider(hint)
        }

        @discardableResult
        func resetContextPressureDetector(panelId: UUID) -> UInt64 {
            terminal(panelId: panelId)?.surface.resetContextPressureDetectors() ?? 0
        }

        func contextPressureDetectorGeneration(panelId: UUID) -> UInt64 {
            terminal(panelId: panelId)?.surface.currentContextPressureDetectorGeneration() ?? 0
        }

        /// Returns the provider-owned lifecycle evidence already published for
        /// this panel. Pressure output often arrives after the hook's idle
        /// event, so a newly-created coordinator state must seed itself from
        /// the authoritative lifecycle map instead of waiting for another
        /// callback that may never arrive.
        func lifecycleEvidence(
            panelId: UUID,
            provider: AgentContextProvider
        ) -> [String: AgentContextLifecycleState] {
            let states: [String: AgentHibernationLifecycleState]
            switch self {
            case .workspace(let workspace):
                states = workspace.agentLifecycleStatesByPanelId[panelId] ?? [:]
            case .dock(let dock):
                states = dock.agentRuntimeByPanelId[panelId]?.agentLifecycleStates ?? [:]
            }
            return states.reduce(into: [:]) { result, entry in
                guard AgentContextProvider(managedAgentKind: entry.key) == provider,
                      let lifecycle = AgentContextLifecycleState(rawValue: entry.value.rawValue) else {
                    return
                }
                result[entry.key] = lifecycle
            }
        }

        /// Returns true for any panel-scoped needs-input lifecycle, including
        /// Feed-owned dialog keys that are intentionally not provider bindings.
        func hasDialogOpen(panelId: UUID) -> Bool {
            switch self {
            case .workspace(let workspace):
                workspace.agentLifecycleStatesByPanelId[panelId]?.values.contains(.needsInput) == true
            case .dock(let dock):
                dock.agentRuntimeByPanelId[panelId]?.agentLifecycleStates.values.contains(.needsInput) == true
            }
        }

        /// Resolves a local handoff path for the panel, rejecting remote
        /// terminal contexts whose cwd exists only on another host.
        func contextHandoffFileURL(panelId: UUID) -> URL? {
            let directory: String?
            switch self {
            case .workspace(let workspace):
                guard !workspace.isRemoteTerminalContext(panelId) else { return nil }
                directory = workspace.panelDirectories[panelId]
                    ?? workspace.terminalPanel(for: panelId)?.requestedWorkingDirectory
                    ?? workspace.currentDirectory
            case .dock(let dock):
                guard dock.detachedSurfaceTransfersByPanelId[panelId]?.isRemoteTerminal != true else {
                    return nil
                }
                directory = dock.terminalWorkingDirectory(for: panelId)
                    ?? dock.panels[panelId].flatMap { ($0 as? TerminalPanel)?.requestedWorkingDirectory }
            }
            guard let directory = directory?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !directory.isEmpty else {
                return nil
            }
            return URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(".cmux-context-handoff.md", isDirectory: false)
        }
    }

    struct PanelState {
        var provider: AgentContextProvider
        var pressure: AgentContextPressureSnapshot
        /// Ordered lifecycle evidence that confirms the pressure episode.
        var pressureConfirmation = AgentContextPressureLifecycleConfirmation()
        var detectorGeneration: UInt64
        /// The exact managed-session binding that produced this state. A
        /// panel id can be reused during respawn/transfer, so pressure must
        /// never cross a session-generation boundary.
        var binding: SurfaceResumeBindingSnapshot?
        var lifecycle: AgentContextLifecycleState = .unknown
        /// Lifecycle evidence keyed by provider hook name. Keeping the keys
        /// lets a clear from one provider invalidate only its own evidence.
        var lifecycleByKey: [String: AgentContextLifecycleState] = [:]
        var shellActivity: PanelShellActivityState = .unknown
        var dialogOpen = false
        var userInputObserved = false
        var injectionInFlight = false
        /// Set only after lifecycle idle and durable handoff-file verification.
        var preservationCompleted = false
        var preservationAwaitingAcknowledgement = false
        var preservationObservedRunning = false
        var preservationHandoffPath: URL?
        var preservationRequestedAt: Date?
        /// A descriptor-bound snapshot captured before the preservation input.
        /// Keeping this compact baseline avoids relying on coarse filesystem
        /// mtimes when the provider writes its handoff note.
        var preservationBaseline: AgentContextHandoffVerificationBaseline?
        var preservationPreparationInFlight = false
        var preservationVerificationInFlight = false
        /// Prevents a recovery command's own compaction output from starting
        /// another recovery cycle until the provider reports a real
        /// running-to-idle boundary.
        var recoveryAwaitingLifecycleBoundary = false
        var recoveryObservedRunning = false
        /// A clear that was deemed unsafe requires an explicit manual recovery
        /// before a later pressure episode can authorize another write.
        var manualRecoveryRequired = false
        /// Provider-originated structured evidence for the current pressure
        /// episode. PTY text alone is diagnostic and never authorizes a write.
        var providerEvidenceConfirmed = false
        /// Receipt time used to discard a pre-compact hook that cannot belong
        /// to the next pressure marker.
        var providerEvidenceReceivedAt: Date?
        var unsafeClearNotificationSent = false
    }

    func makePanelState(
        panelId: UUID,
        provider: AgentContextProvider,
        binding: SurfaceResumeBindingSnapshot,
        owner: PanelOwner,
        pressure: AgentContextPressureSnapshot = AgentContextPressureSnapshot(),
        detectorGeneration: UInt64 = 0,
        userInputObserved: Bool = false,
        seedLifecycleEvidence: Bool = true
    ) -> PanelState {
        let lifecycleByKey = seedLifecycleEvidence
            ? owner.lifecycleEvidence(panelId: panelId, provider: provider)
            : [:]
        let lifecycle = Self.effectiveLifecycle(from: lifecycleByKey.values)
        return PanelState(
            provider: provider,
            pressure: pressure,
            detectorGeneration: detectorGeneration,
            binding: binding,
            lifecycle: lifecycle,
            lifecycleByKey: lifecycleByKey,
            shellActivity: owner.shellActivity(panelId: panelId),
            dialogOpen: lifecycle == .needsInput,
            userInputObserved: userInputObserved
        )
    }

    static func effectiveLifecycle(
        from states: some Collection<AgentContextLifecycleState>
    ) -> AgentContextLifecycleState {
        if states.contains(.running) { return .running }
        if states.contains(.needsInput) { return .needsInput }
        if states.contains(.unknown) { return .unknown }
        if states.contains(.idle) { return .idle }
        return .unknown
    }

    func sameSession(
        _ lhs: SurfaceResumeBindingSnapshot?,
        _ rhs: SurfaceResumeBindingSnapshot
    ) -> Bool {
        guard let lhs else { return false }
        if lhs == rhs { return true }
        return lhs.isAgentHookBinding && rhs.isAgentHookBinding && lhs.isSameManagedSession(as: rhs)
    }

    func sameSession(
        _ lhs: SurfaceResumeBindingSnapshot?,
        _ rhs: SurfaceResumeBindingSnapshot?
    ) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return sameSession(lhs, rhs)
    }
}
