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

    /// Whether quit must enter the asynchronous fresh-index path.
    @MainActor
    var hasLocalTerminalSurfacesForQuit: Bool {
        let managers = mainWindowContexts.values.map(\.tabManager)
            + [tabManager].compactMap { $0 }
        return managers.contains { manager in
            manager.tabs.contains { workspace in
                !workspace.isRemoteWorkspace && !workspace.isRemoteTmuxMirror
                    && workspace.panels.values.contains { $0 is TerminalPanel }
            }
        }
    }

    /// Every panel whose fresh index still proves a live agent process.
    @MainActor
    func quitAgentTerminationScopes(
        index: RestorableAgentSessionIndex
    ) -> [AgentHibernationController.ProcessTerminationScope] {
        agentHibernationRecords(
            index: index,
            activityByPanel: [:],
            terminalInputByPanel: [:],
            lifecycleChangeByPanel: [:]
        )
        .filter(\.hasLiveProcess)
        .map(\.processTerminationScope)
    }

    /// Terminates fresh, validated agent generations after the quit snapshot.
    @MainActor
    func terminateAgentProcessesBeforeQuit(
        index: RestorableAgentSessionIndex
    ) async {
        let scopes = quitAgentTerminationScopes(index: index)
        guard scopes.contains(where: { !$0.processIDs.isEmpty }) else { return }
        let started = ContinuousClock.now
        let outcome = await AgentQuitTerminationCoordinator()
            .terminateAndWait(scopes: scopes)
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
