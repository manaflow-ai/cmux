import Bonsplit
import Foundation

extension Workspace {
    func noteAttachmentTargetForWorkspace() -> CmuxNoteAttachmentTarget {
        .workspace(workspaceAnchorId: noteAnchorId)
    }

    func noteAttachmentTargetForPanel(panelId: UUID, requireTerminal: Bool = false) -> CmuxNoteAttachmentTarget? {
        guard let panel = panels[panelId] else { return nil }
        if requireTerminal, panel.panelType != .terminal {
            return nil
        }
        let surfaceAnchorId = noteAnchorId(forPanelId: panelId)
        return .surface(
            workspaceAnchorId: noteAnchorId,
            surfaceAnchorId: surfaceAnchorId,
            surfaceKind: panel.panelType.rawValue
        )
    }

    func noteAnchorId(forPanelId panelId: UUID) -> String {
        if let existing = noteAnchorIdsByPanelId[panelId] {
            return existing
        }
        let next = CmuxNoteStore.newAnchorID()
        noteAnchorIdsByPanelId[panelId] = next
        postNotesTreeTerminalMetadataDidChange(panelId: panelId)
        return next
    }

    /// Read-only variant of `noteAttachmentTargetForPanel` that never mints a
    /// new anchor. Used to resolve a caller surface's existing notes (e.g.
    /// `note list`/`note here`) without mutating anchor state. Returns nil when
    /// the surface has never had a note attached.
    func existingNoteAttachmentTargetForPanel(panelId: UUID) -> CmuxNoteAttachmentTarget? {
        guard let panel = panels[panelId],
              let surfaceAnchorId = noteAnchorIdsByPanelId[panelId] else {
            return nil
        }
        return .surface(
            workspaceAnchorId: noteAnchorId,
            surfaceAnchorId: surfaceAnchorId,
            surfaceKind: panel.panelType.rawValue
        )
    }

    /// Agent sessions known to run in THIS workspace's panes, for the Notes
    /// tree. Sources, in order: pid-tracked agents (`agentPIDs`) and index
    /// entries whose live pid sits on one of this workspace's pane TTYs. The
    /// TTY pass is what survives app relaunches — reattached agents keep
    /// reporting their previous run's workspace/surface UUIDs through hooks,
    /// so UUID matching alone is not treated as current-run ground truth.
    /// Each entry carries the pane's note anchor (when one was minted, never
    /// minting) so pane-attached flat notes can nest under their session.
    /// Every terminal pane in this workspace, in pane/tab order, as Notes-tree
    /// terminal rows: panel pointer + note anchor (when minted) + tab title.
    func notesTreeObservedTerminals() -> [NotesTreeObservedTerminal] {
        var terminals: [NotesTreeObservedTerminal] = []
        for paneId in bonsplitController.allPaneIds {
            for tab in bonsplitController.tabs(inPane: paneId) {
                guard let panelId = panelIdFromSurfaceId(tab.id),
                      let terminal = panels[panelId] as? TerminalPanel else { continue }
                let title = panelTitle(panelId: panelId) ?? terminal.displayTitle
                terminals.append(NotesTreeObservedTerminal(
                    panelId: panelId.uuidString,
                    anchorId: noteAnchorIdsByPanelId[panelId],
                    title: title
                ))
            }
        }
        return terminals
    }

    func postNotesTreeTerminalMetadataDidChange(panelId: UUID) {
        guard RightSidebarBetaFeatureSettings.isNotesEnabled(),
              panels[panelId] is TerminalPanel else { return }
        NotificationCenter.default.post(
            name: .workspaceNotesTreeTerminalMetadataDidChange,
            object: self,
            userInfo: ["workspaceId": id, "panelId": panelId]
        )
    }

    func notesTreeObservedAgentSessions() async -> NotesTreeObservation {
        SharedLiveAgentIndex.shared.scheduleRefreshIfStale()
        let terminals = notesTreeObservedTerminals()
        let currentTerminalPanelIds = Set(terminals.compactMap { UUID(uuidString: $0.panelId) })
        var seen = Set<String>()
        var observed: [NotesTreeObservedSession] = []
        func add(_ snapshot: SessionRestorableAgentSnapshot, panelId rawPanelId: UUID?) {
            guard let panelId = rawPanelId,
                  currentTerminalPanelIds.contains(panelId) else { return }
            let sessionId = snapshot.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sessionId.isEmpty else { return }
            let key = "\(snapshot.kind.rawValue)\n\(sessionId)"
            guard seen.insert(key).inserted else { return }
            observed.append(NotesTreeObservedSession(
                agent: snapshot.kind.rawValue,
                sessionId: sessionId,
                surfaceAnchorId: noteAnchorIdsByPanelId[panelId],
                terminalPanelId: panelId.uuidString
            ))
        }
        let entries = SharedLiveAgentIndex.shared.index?.allEntries() ?? []
        var pidOwner: [Int: UUID] = [:]
        for (ownerId, keys) in agentPIDKeysByPanelId {
            for key in keys {
                if let pid = agentPIDs[key] { pidOwner[Int(pid)] = ownerId }
            }
        }
        for (_, entry) in entries {
            let pidMatchedOwner = entry.processIDs.compactMap { pidOwner[$0] }.first
            guard let ownerId = pidMatchedOwner else { continue }
            let panelId = panelIdFromSurfaceId(TabID(uuid: ownerId)) ?? ownerId
            add(entry.snapshot, panelId: panelId)
        }
        // TTY pass: ground truth for what is REALLY running in this
        // workspace's panes, regardless of which run's UUIDs the hook records
        // carry — and the only signal at all for bare launches that bypassed
        // the hook wrapper (user PATH/alias shadowing).
        let ttyByPanel = surfaceTTYNames
        guard !ttyByPanel.isEmpty else {
            return NotesTreeObservation(sessions: observed, terminals: terminals)
        }
        var panelByTTY: [String: UUID] = [:]
        for (panelId, tty) in ttyByPanel {
            panelByTTY[NotesTreePaneProcessLookup.normalizeTTY(tty)] = panelId
        }
        let ttys = Array(panelByTTY.keys)
        let paneProcesses = await NotesTreePaneProcessLookup.paneProcessesAsync(ttys: ttys)
        var matchedPanePids = Set<Int>()
        let liveEntries = entries.filter { !$0.entry.processIDs.isEmpty }
        let pidToTTY = Dictionary(
            paneProcesses.map { ($0.pid, $0.tty) }, uniquingKeysWith: { first, _ in first }
        )
        for (_, entry) in liveEntries {
            guard let pid = entry.processIDs.first(where: { pidToTTY[$0] != nil }),
                  let tty = pidToTTY[pid],
                  let ownerId = panelByTTY[tty] else { continue }
            matchedPanePids.formUnion(entry.processIDs)
            let panelId = panelIdFromSurfaceId(TabID(uuid: ownerId)) ?? ownerId
            add(entry.snapshot, panelId: panelId)
        }
        // Hookless agents: an agent-named process on a pane TTY with no hook
        // record anywhere. Report name + start time; the store resolves the
        // session from the cwd's session files.
        var anonymous: [NotesTreeAnonymousAgentObservation] = []
        let builtInAgentIds = Set(SessionAgent.builtInCases.map(\.rawValue))
        for process in paneProcesses where !matchedPanePids.contains(process.pid) {
            let commandAgent = process.command.lowercased()
            // Built-in executable names only: SessionAgent(rawValue:) accepts
            // arbitrary registered ids, which would match every shell on the
            // TTY.
            guard builtInAgentIds.contains(commandAgent) else { continue }
            guard let ownerId = panelByTTY[process.tty],
                  currentTerminalPanelIds.contains(ownerId) else { continue }
            anonymous.append(NotesTreeAnonymousAgentObservation(
                agent: commandAgent,
                startedAt: process.startedAt,
                surfaceAnchorId: noteAnchorIdsByPanelId[ownerId],
                terminalPanelId: ownerId.uuidString
            ))
        }
        #if DEBUG
        cmuxDebugLog(
            "notes.observe ws=\(id.uuidString.prefix(8)) restored=\(restoredAgentSnapshotsByPanelId.count) "
            + "entries=\(entries.count) ttyPanels=\(panelByTTY.count) ttyProcs=\(paneProcesses.count) "
            + "observed=\(observed.count) anon=\(anonymous.count)"
        )
        #endif
        return NotesTreeObservation(sessions: observed, anonymousAgents: anonymous, terminals: terminals)
    }

}
