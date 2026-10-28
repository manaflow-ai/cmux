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
    /// agent checkpoints, workspace evidence, and complete persisted dock
    /// fingerprints. For each pair:
    /// - The window with the higher restore-fidelity score keeps its window
    ///   ID, frame, display and sidebar.
    /// - Workspaces are matched whole, by stable ID, workspace ID, agent
    ///   checkpoints (one copy's set contains the other's), or a unique title
    ///   in the same directory; never by position. A workspace found in only
    ///   one copy is appended.
    /// - A workspace copy is kept whole only when it contains the other's
    ///   agent checkpoints, non-agent panel identities, and preserved content
    ///   fingerprints. Equal evidence
    ///   chooses the higher fidelity score. Divergent panels, groups, or docks
    ///   stay separate, preserving their complete layouts; one original
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
        var signatures: [(signature: CrashWindowSignature, resultIndex: Int)] = []
        var fingerprints = CrashContentFingerprint()
        result.reserveCapacity(snapshot.windows.count)
        var merged = 0
        for window in snapshot.windows {
            let signature = crashWindowSignature(window, fingerprints: &fingerprints)
            if let match = signatures.first(where: { $0.signature.isCrashDuplicate(of: signature) }) {
                let index = match.resultIndex
                let candidate = mergingCrashDuplicateWindows(result[index], window, fingerprints: &fingerprints)
                // Restore caps each window independently. Combining divergent
                // copies past that cap would turn preservation into truncation.
                if let candidate, candidate.tabManager.workspaces.count <= maxWorkspacesPerWindow {
                    result[index] = candidate
                    // Keep observed generations as evidence. The combined result
                    // cannot broaden duplicate identity beyond its inputs.
                    signatures.append((signature, index))
                    merged += 1
                    continue
                }
            }
            signatures.append((signature, result.count))
            result.append(window)
        }
        guard merged > 0 else { return (snapshot, 0) }
        var deduplicated = snapshot
        deduplicated.windows = result
        return (deduplicated, merged)
    }

    private nonisolated static func crashWindowSignature(
        _ window: SessionWindowSnapshot, fingerprints: inout CrashContentFingerprint
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
            dock: crashDockSignature(window.dock, fingerprints: &fingerprints)
        )
    }

    /// Applies a package-owned, one-to-one workspace plan to the app's snapshots.
    private nonisolated static func mergingCrashDuplicateWindows(
        _ lhs: SessionWindowSnapshot,
        _ rhs: SessionWindowSnapshot, fingerprints: inout CrashContentFingerprint
    ) -> SessionWindowSnapshot? {
        // An ownership map cannot distinguish duplicate IDs already present
        // within one input generation. Keep that ambiguous window intact.
        for workspaces in [lhs.tabManager.workspaces, rhs.tabManager.workspaces] {
            let ids = workspaces.compactMap(\.workspaceId)
            guard Set(ids).count == ids.count else { return nil }
        }
        let lhsEvidence = lhs.tabManager.workspaces.map { crashWorkspaceSignature($0, fingerprints: &fingerprints) }
        let rhsEvidence = rhs.tabManager.workspaces.map { crashWorkspaceSignature($0, fingerprints: &fingerprints) }
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
        var mergedWorkspaces = plan.selections.map { selection in
            switch selection {
            case .preferred(let index): return preferredWorkspaces[index]
            case .supplemental(let index): return supplementalWorkspaces[index]
            }
        }
        for (preferredIndex, supplementalIndex) in plan.matches {
            // A legacy richer copy may omit its runtime ID. A proven match
            // retains the other generation's ID so group/dock references survive.
            if mergedWorkspaces[preferredIndex].workspaceId == nil {
                mergedWorkspaces[preferredIndex].workspaceId = preferredWorkspaces[preferredIndex].workspaceId
                    ?? supplementalWorkspaces[supplementalIndex].workspaceId
            }
        }
        // Divergent copies may share an old ID. Give each retained copy its
        // own persisted identity before restore builds its dock-owner lookup.
        var retainedIDs: Set<UUID> = []
        let identitySelector = WorkspaceSessionRestoreIdentity()
        for index in mergedWorkspaces.indices {
            guard let id = mergedWorkspaces[index].workspaceId else { continue }
            if !retainedIDs.insert(id).inserted {
                mergedWorkspaces[index].workspaceId = identitySelector.freshWorkspaceId(reservingIn: &retainedIDs)
            }
        }
        var preferredReplacements: [UUID: UUID] = [:]
        var supplementalReplacements: [UUID: UUID] = [:]
        var preferredIndices: [Int: Int] = [:]
        var supplementalIndices: [Int: Int] = [:]
        for (index, selection) in plan.selections.enumerated() {
            switch selection {
            case .preferred(let source):
                preferredIndices[source] = index
                guard let keptID = mergedWorkspaces[index].workspaceId else { continue }
                if let oldID = preferredWorkspaces[source].workspaceId { preferredReplacements[oldID] = keptID }
            case .supplemental(let source):
                supplementalIndices[source] = index
                guard let keptID = mergedWorkspaces[index].workspaceId else { continue }
                if let oldID = supplementalWorkspaces[source].workspaceId { supplementalReplacements[oldID] = keptID }
            }
        }
        for (preferredIndex, supplementalIndex) in plan.matches {
            preferredIndices[preferredIndex] = preferredIndex
            supplementalIndices[supplementalIndex] = preferredIndex
            guard let keptID = mergedWorkspaces[preferredIndex].workspaceId else { continue }
            if let oldID = preferredWorkspaces[preferredIndex].workspaceId { preferredReplacements[oldID] = keptID }
            if let oldID = supplementalWorkspaces[supplementalIndex].workspaceId { supplementalReplacements[oldID] = keptID }
        }
        for (index, selection) in plan.selections.enumerated() {
            let replacements: [UUID: UUID]
            switch selection {
            case .preferred: replacements = preferredReplacements
            case .supplemental: replacements = supplementalReplacements
            }
            mergedWorkspaces[index].dock = remappingCrashDockOwnership(mergedWorkspaces[index].dock, replacements: replacements)
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
            keptWorkspaces: mergedWorkspaces, identityReplacements: preferredReplacements,
            keptIndicesByOriginalIndex: preferredIndices
        ) ?? []) + (pruningWorkspaceGroups(
            supplementalGroups, originalWorkspaces: supplementalWorkspaces,
            keptWorkspaces: mergedWorkspaces, identityReplacements: supplementalReplacements,
            keptIndicesByOriginalIndex: supplementalIndices
        ) ?? [])
        var merged = preferred
        merged.dock = remappingCrashDockOwnership(preferred.dock, replacements: preferredReplacements)
        merged.tabManager.workspaces = mergedWorkspaces
        merged.tabManager.workspaceGroups = groups.isEmpty ? nil : groups
        return merged
    }

    private nonisolated static func crashWorkspaceSignature(
        _ workspace: SessionWorkspaceSnapshot, fingerprints: inout CrashContentFingerprint
    ) -> CrashWorkspaceSignature {
        CrashWorkspaceSignature(
            stableID: workspace.stableId, workspaceID: workspace.workspaceId,
            checkpointIDs: workspaceCheckpointIDs(workspace),
            title: workspace.customTitle, description: workspace.customDescription,
            groupID: workspace.groupId,
            directory: workspace.currentDirectory.isEmpty ? "" : URL(fileURLWithPath: workspace.currentDirectory).standardizedFileURL.path,
            dock: crashDockSignature(workspace.dock, fingerprints: &fingerprints),
            fidelityScore: sessionWorkspaceRestoreFidelityScore(workspace),
            nonAgentPanelIDs: Set(workspace.panels.compactMap {
                crashPanelCheckpointID($0) == nil ? $0.id : nil
            }),
            preservedContentIDs: crashWorkspaceContentIDs(workspace, fingerprints: &fingerprints),
            metadataFingerprint: crashWorkspaceMetadataFingerprint(workspace, fingerprints: &fingerprints),
            agentPanels: crashAgentPanelSignatures(workspace.panels, fingerprints: &fingerprints)
        )
    }

    private nonisolated static func crashDockSignature(
        _ dock: SessionSplitContainerSnapshot?, fingerprints: inout CrashContentFingerprint
    ) -> CrashDockSignature? {
        dock.map {
            // Ownership is part of the persisted state. Different ownership
            // maps remain separate until correspondence is known; never erase
            // an ownership distinction merely to make the windows match.
            CrashDockSignature(
                panelIDs: Set($0.panels.map(\.id)), checkpointIDs: crashPanelCheckpointIDs($0.panels),
                contentFingerprint: fingerprints.fingerprint($0)
            )
        }
    }

    /// Preserve all persisted non-agent contents. Exhausting
    /// the comparison budget retains both copies instead of using sampled text.
    private nonisolated static func crashWorkspaceContentIDs(
        _ workspace: SessionWorkspaceSnapshot, fingerprints: inout CrashContentFingerprint
    ) -> Set<String>? {
        var contents: Set<String> = []
        for panel in workspace.panels where crashPanelCheckpointID(panel) == nil {
            guard let fingerprint = fingerprints.fingerprint(panel) else { return nil }
            contents.insert("panel:\(panel.id):\(fingerprint)")
        }
        return contents
    }

    /// Keep pane metadata and its contents together, even when checkpoints repeat.
    private nonisolated static func crashAgentPanelSignatures(
        _ panels: [SessionPanelSnapshot], fingerprints: inout CrashContentFingerprint
    ) -> [CrashAgentPanelSignature]? {
        var signatures: [CrashAgentPanelSignature] = []
        for panel in panels {
            guard let checkpoint = crashPanelCheckpointID(panel) else { continue }
            var contents: Set<String> = []
            if let scrollback = panel.terminal?.scrollback, !scrollback.isEmpty {
                guard let fingerprint = fingerprints.fingerprint(scrollback) else { return nil }
                contents.insert("scrollback:\(fingerprint)")
            }
            if let draft = panel.terminal?.textBoxDraft {
                guard let fingerprint = fingerprints.fingerprint(draft) else { return nil }
                contents.insert("draft:\(fingerprint)")
            }
            if let launch = panel.terminal?.agent?.launchCommand {
                guard let fingerprint = fingerprints.fingerprint(launch) else { return nil }
                contents.insert("launch:\(fingerprint)")
            }
            for (name, binding) in [
                ("resume", panel.terminal?.resumeBinding), ("managed", panel.terminal?.managedAgentResumeBinding)
            ] {
                guard var binding else { continue }
                binding.cwd = nil
                binding.updatedAt = 0
                guard let fingerprint = fingerprints.fingerprint(binding) else { return nil }
                contents.insert("\(name):\(fingerprint)")
            }
            var metadata = panel
            // Pane IDs and process titles change across generations. Working
            // directories come from the retained complete generation's fidelity.
            metadata.id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            metadata.stableSurfaceId = nil
            metadata.title = nil
            metadata.directory = nil
            metadata.terminal?.workingDirectory = nil
            metadata.terminal?.agent?.workingDirectory = nil
            metadata.terminal?.agent?.launchCommand = nil
            metadata.terminal?.scrollback = nil
            metadata.terminal?.textBoxDraft = nil
            metadata.terminal?.resumeBinding = nil
            metadata.terminal?.managedAgentResumeBinding = nil
            guard let fingerprint = fingerprints.fingerprint(metadata) else { return nil }
            signatures.append(CrashAgentPanelSignature(
                checkpointID: checkpoint, metadataFingerprint: fingerprint, contentFingerprints: contents
            ))
        }
        return signatures
    }

    /// User-authored workspace state must agree before a whole copy is lost.
    /// Runtime IDs, focus/layout, and recovered working directories belong to
    /// the chosen complete generation; panels and docks have their own checks.
    private nonisolated static func crashWorkspaceMetadataFingerprint(
        _ workspace: SessionWorkspaceSnapshot, fingerprints: inout CrashContentFingerprint
    ) -> String? {
        var metadata = workspace
        metadata.workspaceId = nil
        metadata.stableId = nil
        metadata.processTitle = ""
        metadata.currentDirectory = ""
        metadata.focusedPanelId = nil
        metadata.layout = .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil))
        metadata.canvasPanes = nil
        metadata.panels = []
        metadata.dock = nil
        return fingerprints.fingerprint(metadata)
    }

    private nonisolated static func remappingCrashDockOwnership(
        _ dock: SessionSplitContainerSnapshot?, replacements: [UUID: UUID]
    ) -> SessionSplitContainerSnapshot? {
        guard var dock else { return nil }
        dock.sourceWorkspaceIdsByPanelId = dock.sourceWorkspaceIdsByPanelId?.mapValues { replacements[$0] ?? $0 }
        return dock
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
        Set(panels.compactMap(crashPanelCheckpointID))
    }

    private nonisolated static func crashPanelCheckpointID(_ panel: SessionPanelSnapshot) -> String? {
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
