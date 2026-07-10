import Foundation

extension ClosedItemHistoryStore {
    /// Records the core close snapshot immediately, then enriches it from an
    /// off-main capture while the caller retains the terminal being closed.
    @discardableResult
    func pushPreservingAgentMetadata(
        _ entry: ClosedItemHistoryEntry,
        coordinatedBy sharedIndex: SharedLiveAgentIndex = .shared
    ) -> Task<Void, Never>? {
        let cachedIndex = sharedIndex.cachedIndex()
        let initialEntry = cachedIndex.map { entry.enrichingAgentMetadata(from: $0) } ?? entry
        let record = ClosedItemHistoryRecord(entry: initialEntry)
        guard cachedIndex == nil else {
            push(record)
            return nil
        }
        pushPendingEnrichment(record)
        let refreshTask = sharedIndex.indexRefreshTaskForDestructiveClose()
        return Task { @MainActor [weak self] in
            guard let self else { return }
            let index = await refreshTask.value
            let capturedEntry = index.map {
                record.entry.enrichingAgentMetadata(from: $0)
            } ?? record.entry
            self.resolvePendingEnrichment(recordID: record.id) { currentEntry in
                currentEntry.mergingCapturedAgentMetadata(from: capturedEntry)
            }
        }
    }
}

@MainActor
final class AgentMetadataCloseDeferrer {
    private var tasksByID: [UUID: Task<Void, Never>] = [:]

    @discardableResult
    func deferClose(
        id: UUID,
        until captureTask: Task<Void, Never>,
        close: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        tasksByID[id]?.cancel()
        let task = Task { @MainActor [weak self] in
            await captureTask.value
            guard !Task.isCancelled else { return }
            close()
            self?.tasksByID.removeValue(forKey: id)
        }
        tasksByID[id] = task
        return task
    }

    func isDeferringClose(id: UUID) -> Bool {
        tasksByID[id] != nil
    }
}

extension ClosedItemHistoryEntry {
    func mergingCapturedAgentMetadata(
        from capturedEntry: ClosedItemHistoryEntry
    ) -> ClosedItemHistoryEntry {
        switch (self, capturedEntry) {
        case (.panel(let current), .panel(let captured)):
            return .panel(ClosedPanelHistoryEntry(
                workspaceId: current.workspaceId,
                paneId: current.paneId,
                paneAnchorPanelId: current.paneAnchorPanelId,
                restoreInOriginalPane: current.restoreInOriginalPane,
                tabIndex: current.tabIndex,
                snapshot: current.snapshot.mergingAgentMetadata(from: captured.snapshot),
                fallbackSplitPlacement: current.fallbackSplitPlacement
            ))
        case (.workspace(let current), .workspace(let captured)):
            var snapshot = current.snapshot
            snapshot.panels = current.snapshot.panels.enumerated().map { index, panel in
                guard captured.snapshot.panels.indices.contains(index) else { return panel }
                return panel.mergingAgentMetadata(from: captured.snapshot.panels[index])
            }
            return .workspace(ClosedWorkspaceHistoryEntry(
                workspaceId: current.workspaceId,
                windowId: current.windowId,
                workspaceIndex: current.workspaceIndex,
                snapshot: snapshot
            ))
        case (.window(let current), .window(let captured)):
            var snapshot = current.snapshot
            snapshot.tabManager.workspaces = current.snapshot.tabManager.workspaces.enumerated().map {
                workspaceIndex, workspace in
                guard captured.snapshot.tabManager.workspaces.indices.contains(workspaceIndex) else {
                    return workspace
                }
                let capturedWorkspace = captured.snapshot.tabManager.workspaces[workspaceIndex]
                var mergedWorkspace = workspace
                mergedWorkspace.panels = workspace.panels.enumerated().map { panelIndex, panel in
                    guard capturedWorkspace.panels.indices.contains(panelIndex) else { return panel }
                    return panel.mergingAgentMetadata(from: capturedWorkspace.panels[panelIndex])
                }
                return mergedWorkspace
            }
            return .window(ClosedWindowHistoryEntry(
                windowId: current.windowId,
                snapshot: snapshot,
                workspaceIds: current.workspaceIds
            ))
        default:
            return self
        }
    }

    func enrichingAgentMetadata(
        from index: RestorableAgentSessionIndex
    ) -> ClosedItemHistoryEntry {
        switch self {
        case .panel(let entry):
            return .panel(ClosedPanelHistoryEntry(
                workspaceId: entry.workspaceId,
                paneId: entry.paneId,
                paneAnchorPanelId: entry.paneAnchorPanelId,
                restoreInOriginalPane: entry.restoreInOriginalPane,
                tabIndex: entry.tabIndex,
                snapshot: Self.enriching(
                    entry.snapshot,
                    workspaceId: entry.workspaceId,
                    index: index
                ),
                fallbackSplitPlacement: entry.fallbackSplitPlacement
            ))
        case .workspace(let entry):
            var snapshot = entry.snapshot
            let workspaceId = snapshot.workspaceId ?? entry.workspaceId
            snapshot.panels = snapshot.panels.map {
                Self.enriching($0, workspaceId: workspaceId, index: index)
            }
            return .workspace(ClosedWorkspaceHistoryEntry(
                workspaceId: entry.workspaceId,
                windowId: entry.windowId,
                workspaceIndex: entry.workspaceIndex,
                snapshot: snapshot
            ))
        case .window(let entry):
            var snapshot = entry.snapshot
            snapshot.tabManager.workspaces = snapshot.tabManager.workspaces.map { workspace in
                guard let workspaceId = workspace.workspaceId else { return workspace }
                var enrichedWorkspace = workspace
                enrichedWorkspace.panels = workspace.panels.map {
                    Self.enriching($0, workspaceId: workspaceId, index: index)
                }
                return enrichedWorkspace
            }
            return .window(ClosedWindowHistoryEntry(
                windowId: entry.windowId,
                snapshot: snapshot,
                workspaceIds: entry.workspaceIds
            ))
        }
    }

    private static func enriching(
        _ panel: SessionPanelSnapshot,
        workspaceId: UUID,
        index: RestorableAgentSessionIndex
    ) -> SessionPanelSnapshot {
        guard var terminal = panel.terminal,
              terminal.agent == nil,
              let indexedAgent = index.snapshot(workspaceId: workspaceId, panelId: panel.id),
              let restorableAgent = Workspace.restorableAgentForSessionRestore(
                indexedAgent,
                resumeBinding: terminal.resumeBinding
              ) else {
            return panel
        }

        var enrichedPanel = panel
        terminal.agent = restorableAgent
        terminal.tmuxStartCommand = nil
        if terminal.workingDirectory == nil {
            terminal.workingDirectory = restorableAgent.workingDirectory
        }
        if terminal.wasAgentRunning == nil {
            terminal.wasAgentRunning = true
        }
        enrichedPanel.terminal = terminal
        if enrichedPanel.directory == nil {
            enrichedPanel.directory = restorableAgent.workingDirectory
        }
        return enrichedPanel
    }
}

private extension SessionPanelSnapshot {
    func mergingAgentMetadata(from captured: SessionPanelSnapshot) -> SessionPanelSnapshot {
        guard var currentTerminal = terminal,
              currentTerminal.agent == nil,
              let capturedTerminal = captured.terminal,
              let capturedAgent = capturedTerminal.agent else {
            return self
        }
        var merged = self
        currentTerminal.agent = capturedAgent
        currentTerminal.tmuxStartCommand = capturedTerminal.tmuxStartCommand
        if currentTerminal.workingDirectory == nil {
            currentTerminal.workingDirectory = capturedTerminal.workingDirectory
        }
        if currentTerminal.wasAgentRunning == nil {
            currentTerminal.wasAgentRunning = capturedTerminal.wasAgentRunning
        }
        merged.terminal = currentTerminal
        if merged.directory == nil {
            merged.directory = captured.directory
        }
        return merged
    }
}
