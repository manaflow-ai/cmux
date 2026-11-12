import Foundation

extension AppDelegate {
    enum TerminateCleanupPhase: Equatable, Sendable {
        case ownedRuntimeCleanup
        case freshSnapshot
        case agentTermination
    }

    enum TerminateCleanupDeadlineDisposition: Equatable, Sendable {
        case persistCachedSnapshotAndTerminate
        case terminateWithSavedSnapshot
        case cancelTerminationAfterRuntimeCleanupFailure
    }

    private typealias QuitOwnerCheck = @MainActor @Sendable () -> Bool

    /// Terminal ownership, not a cached process scan, decides whether quit must defer.
    var hasLocalTerminalSurfacesForQuit: Bool { !localTerminalQuitOwners().isEmpty }

    /// Captures workspace, Dock, and windowless owners without creating new surfaces.
    private func localTerminalQuitOwners() -> [AgentHibernationPanelKey: QuitOwnerCheck] {
        var owners: [AgentHibernationPanelKey: QuitOwnerCheck] = [:]
        let managers = mainWindowSessionPersistenceRoutes().map(\.tabManager)
            + [tabManager].compactMap { $0 }
        var seenManagers: Set<ObjectIdentifier> = []
        func append(_ dock: DockSplitStore) {
            for (panelID, panel) in dock.panels {
                guard let terminal = panel as? TerminalPanel,
                      !dock.terminalLinkIsRemoteTerminal(panelID) else { continue }
                let key = AgentHibernationPanelKey(workspaceId: dock.workspaceId, panelId: panelID)
                owners[key] = { [weak dock, weak terminal] in
                    guard let dock, let terminal else { return false }
                    return dock.panels[panelID] === terminal && !dock.terminalLinkIsRemoteTerminal(panelID)
                }
            }
        }
        for manager in managers where seenManagers.insert(ObjectIdentifier(manager)).inserted {
            for workspace in manager.tabs where !workspace.isRemoteWorkspace && !workspace.isRemoteTmuxMirror {
                for (panelID, panel) in workspace.panels {
                    guard let terminal = panel as? TerminalPanel else { continue }
                    let key = AgentHibernationPanelKey(workspaceId: workspace.id, panelId: panelID)
                    owners[key] = { [weak workspace, weak terminal] in
                        guard let workspace, let terminal else { return false }
                        return workspace.panels[panelID] === terminal
                            && !workspace.isRemoteWorkspace && !workspace.isRemoteTmuxMirror
                    }
                }
                if let dock = workspace._dockSplit { append(dock) }
            }
        }
        for dock in existingWindowDocks { append(dock) }
        return owners
    }

    /// Only complete Codex process scopes in locally owned panels can be quit targets.
    func quitAgentTerminationScopes(
        index: RestorableAgentSessionIndex
    ) -> [AgentHibernationController.ProcessTerminationScope] {
        quitAgentTerminationScopes(index: index, owners: localTerminalQuitOwners())
    }

    private func quitAgentTerminationScopes(
        index: RestorableAgentSessionIndex,
        owners: [AgentHibernationPanelKey: QuitOwnerCheck]
    ) -> [AgentHibernationController.ProcessTerminationScope] {
        owners.keys.compactMap { key in
            guard let entry = index.exactEntry(workspaceId: key.workspaceId, panelId: key.panelId),
                  entry.snapshot.kind == .codex, entry.processLiveness == .running,
                  entry.processSafetyAllowsScheduledHibernation else { return nil }
            return AgentHibernationController.ProcessTerminationScope(
                key: key, processIDs: entry.terminationProcessIDs,
                processIdentities: entry.terminationProcessIdentities
            )
        }
    }

    /// Terminates fresh, validated agent generations after the quit snapshot.
    @MainActor
    func terminateAgentProcessesBeforeQuit(
        index: RestorableAgentSessionIndex
    ) async {
        let owners = localTerminalQuitOwners()
        let scopes = quitAgentTerminationScopes(index: index, owners: owners)
        guard scopes.contains(where: { !$0.processIDs.isEmpty }) else { return }
        let started = ContinuousClock.now
        let outcome = await AgentQuitTerminationCoordinator()
            .terminateAndWait(scopes: scopes) { [weak self] key in
                self?.isTerminatingApp == true && owners[key]?() == true
            }
        let elapsed = started.duration(to: .now).components
        StartupBreadcrumbLog.append(
            "appDelegate.shouldTerminate.agentTermination",
            fields: [
                "targets": String(outcome.targetPanels),
                "exited": String(outcome.exitedPanels),
                "rejected": String(outcome.rejectedPanels),
                "survivors": String(outcome.survivingPanels),
                "ms": String(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000),
            ]
        )
    }

    nonisolated static func terminateCleanupDeadlineDisposition(
        phase: TerminateCleanupPhase?,
        hasOwnedRuntimeCleanup: Bool
    ) -> TerminateCleanupDeadlineDisposition {
        if phase == .agentTermination { return .terminateWithSavedSnapshot }
        if phase == .freshSnapshot || !hasOwnedRuntimeCleanup {
            return .persistCachedSnapshotAndTerminate
        }
        return .cancelTerminationAfterRuntimeCleanupFailure
    }
}
