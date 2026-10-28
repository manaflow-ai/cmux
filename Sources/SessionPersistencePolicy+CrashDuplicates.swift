import Foundation
import CmuxWorkspaces
import CryptoKit

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
        var signatures: [CrashWindowSignature] = []
        var mergedClusters: Set<Int> = []
        result.reserveCapacity(snapshot.windows.count)
        var merged = 0
        for window in snapshot.windows {
            let signature = crashWindowSignature(window)
            if let index = signatures.indices.first(where: { index in
                signatures[index].isCrashDuplicate(of: signature)
                    || (mergedClusters.contains(index)
                        && signatures[index].isCrashClusterContinuation(of: signature))
            }) {
                result[index] = mergingCrashDuplicateWindows(result[index], window)
                signatures[index] = crashWindowSignature(result[index])
                mergedClusters.insert(index)
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
        var mergedWorkspaces = plan.selections.map { selection in
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
        let replacements = preferredReplacements.merging(supplementalReplacements) { preferred, _ in preferred }
        for index in mergedWorkspaces.indices {
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
            keptWorkspaces: mergedWorkspaces, identityReplacements: preferredReplacements
        ) ?? []) + (pruningWorkspaceGroups(
            supplementalGroups, originalWorkspaces: supplementalWorkspaces,
            keptWorkspaces: mergedWorkspaces, identityReplacements: supplementalReplacements
        ) ?? [])
        var merged = preferred
        merged.dock = remappingCrashDockOwnership(preferred.dock, replacements: replacements)
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
            fidelityScore: sessionWorkspaceRestoreFidelityScore(workspace),
            nonAgentPanelIDs: Set(workspace.panels.compactMap {
                crashPanelCheckpointID($0) == nil ? $0.id : nil
            }),
            preservedContentIDs: crashWorkspaceContentIDs(workspace)
        )
    }

    private nonisolated static func crashDockSignature(_ dock: SessionSplitContainerSnapshot?) -> CrashDockSignature? {
        dock.map {
            var normalized = $0
            // Ownership IDs are remapped after workspace matching. Excluding
            // them here lets an otherwise identical replay reach that remap.
            normalized.sourceWorkspaceIdsByPanelId = nil
            CrashDockSignature(
                panelIDs: Set(normalized.panels.map(\.id)), checkpointIDs: crashPanelCheckpointIDs(normalized.panels),
                contentFingerprint: crashDockContentFingerprint(normalized)
            )
        }
    }

    /// Preserve complete non-agent panel contents and agent text independently of metadata scores.
    private nonisolated static func crashWorkspaceContentIDs(_ workspace: SessionWorkspaceSnapshot) -> Set<String>? {
        var contents: Set<String> = []
        for panel in workspace.panels {
            guard let checkpoint = crashPanelCheckpointID(panel) else {
                guard let fingerprint = crashPanelContentFingerprint(panel) else { return nil }
                contents.insert("panel:\(panel.id):\(fingerprint)")
                continue
            }
            if let scrollback = panel.terminal?.scrollback, !scrollback.isEmpty {
                guard let fingerprint = crashTextContentFingerprint(scrollback) else { return nil }
                contents.insert("scrollback:\(checkpoint):\(fingerprint)")
            }
            if let draft = panel.terminal?.textBoxDraft {
                guard let fingerprint = crashDraftContentFingerprint(draft) else { return nil }
                contents.insert("draft:\(checkpoint):\(fingerprint)")
            }
        }
        return contents
    }

    private static let crashFingerprintTextLimit = 16_384

    private nonisolated static func boundedCrashText(_ value: String?) -> String {
        guard let value else { return "<nil>" }
        let prefix = String(value.prefix(crashFingerprintTextLimit))
        let suffix = String(value.suffix(crashFingerprintTextLimit))
        return "\(value.utf8.count):\(prefix):\(suffix)"
    }

    private nonisolated static func digestCrashComponents(_ components: [String?]) -> String {
        let joined = components.map { boundedCrashText($0) }.joined(separator: "\u{1f}")
        return Data(SHA256.hash(data: Data(joined.utf8))).base64EncodedString()
    }

    private nonisolated static func crashTextContentFingerprint(_ value: String) -> String? {
        digestCrashComponents([value])
    }

    private nonisolated static func crashDraftContentFingerprint(
        _ draft: SessionTextBoxInputDraftSnapshot
    ) -> String? {
        var components: [String?] = [draft.isActive ? "active" : "inactive"]
        for part in draft.parts {
            components.append(part.kind.rawValue)
            components.append(part.text)
            if let attachment = part.attachment {
                components += [attachment.displayName, attachment.submissionPath, attachment.submissionText]
            }
        }
        return digestCrashComponents(components)
    }

    private nonisolated static func crashPanelContentFingerprint(
        _ panel: SessionPanelSnapshot
    ) -> String? {
        var components: [String?] = [
            String(describing: panel.type), panel.title, panel.customTitle,
            panel.directory, panel.ttyName, panel.gitBranch?.branch
        ]
        if let browser = panel.browser {
            components += [browser.urlString, browser.profileID?.uuidString]
            components += (browser.backHistoryURLStrings ?? []).map(Optional.some)
            components += (browser.forwardHistoryURLStrings ?? []).map(Optional.some)
            components += [browser.diffViewerRequestPath, browser.cloudTeamID,
                           browser.interactionState.map(crashDataContentFingerprint)]
        }
        if let markdown = panel.markdown { components.append(markdown.filePath) }
        if let filePreview = panel.filePreview { components.append(filePreview.filePath) }
        if let project = panel.project {
            components += [project.projectPath, project.selectedNodePath, project.activeTab]
        }
        if let chief = panel.chief {
            components.append(chief.conversationID)
        }
        if let customSidebar = panel.customSidebar { components.append(customSidebar.name) }
        if let terminal = panel.terminal {
            components += [terminal.workingDirectory, terminal.scrollback]
            if let draft = terminal.textBoxDraft { components.append(crashDraftContentFingerprint(draft)) }
        }
        return digestCrashComponents(components)
    }

    private nonisolated static func crashDataContentFingerprint(_ data: Data) -> String {
        let limit = min(data.count, crashFingerprintTextLimit)
        var sample = Data(data.prefix(limit))
        if data.count > limit {
            sample.append(data.suffix(limit))
        }
        return "\(data.count):\(Data(SHA256.hash(data: sample)).base64EncodedString())"
    }

    private nonisolated static func crashDockContentFingerprint(
        _ dock: SessionSplitContainerSnapshot
    ) -> String? {
        let panelContents = dock.panels.sorted { $0.id.uuidString < $1.id.uuidString }.compactMap {
            guard let content = crashPanelContentFingerprint($0) else { return nil }
            return "\($0.id.uuidString):\(content)"
        }
        guard panelContents.count == dock.panels.count else { return nil }
        return digestCrashComponents([
            String(describing: dock.layout), dock.focusedPanelId?.uuidString,
            panelContents.joined(separator: "|")
        ])
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
