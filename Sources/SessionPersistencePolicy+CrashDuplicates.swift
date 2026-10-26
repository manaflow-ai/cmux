import Foundation
import CmuxWorkspaces

extension SessionPersistencePolicy {
    /// The snapshot a live restore opens: crash-diagnostic windows pruned,
    /// scrollback recovered (when given), then crash-duplicate windows
    /// merged. Every live restore uses it: the automatic startup restore and
    /// its history fallback, the manual reopen, and `restore-session` import.
    /// Nil when nothing restorable is left.
    nonisolated static func snapshotForLiveRestore(
        _ snapshot: AppSessionSnapshot,
        recoveringScrollback: (AppSessionSnapshot) -> AppSessionSnapshot = { $0 }
    ) -> AppSessionSnapshot? {
        guard let pruned = pruningCmuxCrashDiagnosticWindows(from: snapshot).snapshot else {
            return nil
        }
        return mergingCrashDuplicateWindows(in: recoveringScrollback(pruned)).snapshot
    }

    /// Merges the windows a crash wrote twice, before restore opens them.
    ///
    /// A crash can leave the same window in the snapshot twice, sometimes
    /// under a new window ID; restoring both opens every workspace twice.
    /// `CrashWindowSignature.isCrashDuplicate(of:)` decides which windows are the same, using
    /// agent checkpoints only (see `workspaceCheckpointIDs`). For each pair:
    /// - The window with the higher restore-fidelity score keeps its window
    ///   ID, frame, display and sidebar.
    /// - Workspaces are matched whole, by stable ID, workspace ID, agent
    ///   checkpoints (one copy's set contains the other's), or a unique title
    ///   in the same directory; never by position. A workspace found in only
    ///   one copy is appended.
    /// - Of two matched workspaces one is kept whole and the other dropped,
    ///   with its unique non-agent panels (plain terminals, browsers, splits): the copy
    ///   whose agent checkpoints strictly contain the other's, otherwise the
    ///   one with the higher fidelity score.
    ///   Divergent agent sets or different docks stay separate; one original
    ///   workspace can match at most one workspace in the other generation.
    /// - Three or more copies of a window collapse into one, pair by pair.
    ///
    /// Only the live restore merges; pruning and the manual-restore sync
    /// don't, so the launch's `-previous` copy and rotated history keep every
    /// window. The restored layout is saved afterwards like any other: the
    /// overwrite guard holds poorer saves for up to its 5-minute maturity
    /// window, then autosave writes the merged layout, and the next launch
    /// copies it into `-previous`.
    nonisolated static func mergingCrashDuplicateWindows(
        in snapshot: AppSessionSnapshot
    ) -> (snapshot: AppSessionSnapshot, mergedWindowCount: Int) {
        var result: [SessionWindowSnapshot] = []
        var signatures: [CrashWindowSignature] = []
        result.reserveCapacity(snapshot.windows.count)
        var merged = 0
        for window in snapshot.windows {
            let signature = crashWindowSignature(window)
            if let index = signatures.firstIndex(where: {
                $0.isCrashDuplicate(of: signature)
            }) {
                result[index] = mergingCrashDuplicateWindows(result[index], window)
                signatures[index] = crashWindowSignature(result[index])
                merged += 1
                continue
            }
            result.append(window)
            signatures.append(signature)
        }
        guard merged > 0 else { return (snapshot, 0) }
        var deduplicated = snapshot
        deduplicated.windows = result
        return (deduplicated, merged)
    }

    private nonisolated static func crashWindowSignature(
        _ window: SessionWindowSnapshot
    ) -> CrashWindowSignature {
        let workspaces = window.tabManager.workspaces
        let workspaceIDs = workspaces.compactMap(\.workspaceId)
        let titles = workspaces.compactMap { workspace -> String? in
            let title = workspace.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? nil : title
        }
        return CrashWindowSignature(
            windowId: window.windowId,
            workspaceCount: workspaces.count,
            workspaceIDs: workspaceIDs.count == workspaces.count ? workspaceIDs : nil,
            checkpointIDs: crashWindowCheckpointIDs(window),
            workspaceTitles: titles,
            dock: crashDockSignature(window.dock)
        )
    }

    /// Applies a package-owned, one-to-one workspace plan to the app's snapshots.
    private nonisolated static func mergingCrashDuplicateWindows(
        _ lhs: SessionWindowSnapshot,
        _ rhs: SessionWindowSnapshot
    ) -> SessionWindowSnapshot {
        let lhsEvidence = lhs.tabManager.workspaces.map(crashWorkspaceSignature)
        let rhsEvidence = rhs.tabManager.workspaces.map(crashWorkspaceSignature)
        let lhsIsRicher = lhsEvidence.reduce(0) { $0 + $1.fidelityScore } >=
            rhsEvidence.reduce(0) { $0 + $1.fidelityScore }
        let preferred = lhsIsRicher ? lhs : rhs
        let supplemental = lhsIsRicher ? rhs : lhs
        let plan = CrashWorkspaceMergePlan(
            preferred: lhsIsRicher ? lhsEvidence : rhsEvidence,
            supplemental: lhsIsRicher ? rhsEvidence : lhsEvidence
        )
        let preferredWorkspaces = preferred.tabManager.workspaces
        let supplementalWorkspaces = supplemental.tabManager.workspaces
        let mergedWorkspaces = plan.selections.map { selection in
            switch selection {
            case .preferred(let index): return preferredWorkspaces[index]
            case .supplemental(let index): return supplementalWorkspaces[index]
            }
        }
        var preferredReplacements: [UUID: UUID] = [:]
        var supplementalReplacements: [UUID: UUID] = [:]
        for (preferredIndex, supplementalIndex) in plan.matches {
            guard let keptID = mergedWorkspaces[preferredIndex].workspaceId else { continue }
            if let oldID = preferredWorkspaces[preferredIndex].workspaceId { preferredReplacements[oldID] = keptID }
            if let oldID = supplementalWorkspaces[supplementalIndex].workspaceId { supplementalReplacements[oldID] = keptID }
        }
        let preferredGroups = preferred.tabManager.workspaceGroups ?? []
        let preferredGroupIDs = Set(preferredGroups.map(\.id))
        let supplementalGroups = (supplemental.tabManager.workspaceGroups ?? []).filter {
            !preferredGroupIDs.contains($0.id)
        }
        // Resolve legacy anchor indices in the generation that owned each group,
        // then translate replaced workspace identities before pruning its members.
        let groups = (pruningWorkspaceGroups(
            preferredGroups, originalWorkspaces: preferredWorkspaces,
            keptWorkspaces: mergedWorkspaces, identityReplacements: preferredReplacements
        ) ?? []) + (pruningWorkspaceGroups(
            supplementalGroups, originalWorkspaces: supplementalWorkspaces,
            keptWorkspaces: mergedWorkspaces, identityReplacements: supplementalReplacements
        ) ?? [])
        var merged = preferred
        merged.tabManager.workspaces = mergedWorkspaces
        merged.tabManager.workspaceGroups = groups.isEmpty ? nil : groups
        return merged
    }

    private nonisolated static func crashWorkspaceSignature(_ workspace: SessionWorkspaceSnapshot) -> CrashWorkspaceSignature {
        CrashWorkspaceSignature(
            stableID: workspace.stableId, workspaceID: workspace.workspaceId,
            checkpointIDs: workspaceCheckpointIDs(workspace),
            title: workspace.customTitle, description: workspace.customDescription,
            groupID: workspace.groupId,
            directory: workspace.currentDirectory.isEmpty ? "" : URL(fileURLWithPath: workspace.currentDirectory).standardizedFileURL.path,
            dock: crashDockSignature(workspace.dock),
            fidelityScore: sessionWorkspaceRestoreFidelityScore(workspace)
        )
    }

    private nonisolated static func crashDockSignature(_ dock: SessionSplitContainerSnapshot?) -> CrashDockSignature? {
        dock.map { CrashDockSignature(panelIDs: Set($0.panels.map(\.id)), checkpointIDs: crashPanelCheckpointIDs($0.panels)) }
    }

    private nonisolated static func crashWindowCheckpointIDs(
        _ window: SessionWindowSnapshot
    ) -> Set<String> {
        Set(window.tabManager.workspaces.flatMap(workspaceCheckpointIDs))
            .union(crashPanelCheckpointIDs(window.dock?.panels ?? []))
    }

    /// Agent sessions only: the restorable agent's session ID, an agent-hook
    /// resume binding, or the managed-agent binding. One agent session runs
    /// in one place, which is what makes a shared checkpoint evidence of a
    /// duplicate. The rare exception is a Claude or Codex session resumed in
    /// two panes without forking, which keeps one session ID in both; that
    /// is deliberate sharing, and two such windows only merge when their
    /// titles and workspace counts match too. Excluded: process-detected
    /// bindings (tmux and herdr session names, which two real windows can
    /// share) and bindings from an untrusted `restore-session` import.
    /// A panel whose agent left no checkpoint contributes nothing, so partial
    /// metadata can only make a merge less likely.
    private nonisolated static func workspaceCheckpointIDs(
        _ workspace: SessionWorkspaceSnapshot
    ) -> Set<String> {
        crashPanelCheckpointIDs(workspace.panels).union(crashPanelCheckpointIDs(workspace.dock?.panels ?? []))
    }

    private nonisolated static func crashPanelCheckpointIDs(_ panels: [SessionPanelSnapshot]) -> Set<String> {
        Set(panels.compactMap { panel in
            guard let terminal = panel.terminal else { return nil }
            if let sessionId = terminal.agent?.sessionId { return sessionId }
            if let binding = terminal.resumeBinding, binding.isAgentHookBinding,
               let checkpoint = binding.checkpointId {
                return checkpoint
            }
            guard let managed = terminal.managedAgentResumeBinding,
                  !managed.isProcessDetected,
                  managed.source != SurfaceResumeBindingSnapshot.untrustedSessionImportSource else {
                return nil
            }
            return managed.checkpointId
        })
    }

    private nonisolated static func sessionWorkspaceRestoreFidelityScore(
        _ workspace: SessionWorkspaceSnapshot
    ) -> Int {
        workspace.panels.reduce(
            (workspace.workspaceId == nil ? 0 : 1) +
                (workspace.currentDirectory.isEmpty ? 0 : 1)
        ) { score, panel in
            let binding = panel.terminal?.resumeBinding ?? panel.terminal?.managedAgentResumeBinding
            return score
                + (panel.directory == nil ? 0 : 1)
                + (panel.terminal?.workingDirectory == nil ? 0 : 4)
                + (panel.terminal?.agent?.workingDirectory == nil ? 0 : 4)
                + (panel.terminal?.agent?.launchCommand == nil ? 0 : 3)
                + (binding?.cwd == nil ? 0 : 3)
                + (binding?.launchCommand == nil ? 0 : 2)
                + (binding?.isAgentHookBinding == true ? 2 : 0)
        }
    }

}
