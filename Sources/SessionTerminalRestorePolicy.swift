import Foundation

/// Applies the terminal-session restore preference at every persisted-session
/// boundary. Explicit closed-item restores opt out of this policy at their
/// call site; relaunch and manual previous-launch restores use it by default.
struct SessionTerminalRestorePolicy {
    let restoreTerminalSessions: Bool

    init(restoreTerminalSessions: Bool) {
        self.restoreTerminalSessions = restoreTerminalSessions
    }

    init(defaults: UserDefaults = .standard) {
        self.init(
            restoreTerminalSessions: TerminalSessionRestoreSettings.isEnabled(
                defaults: defaults
            )
        )
    }

    func appSnapshotForRestore(_ snapshot: AppSessionSnapshot) -> AppSessionSnapshot? {
        guard !restoreTerminalSessions else { return snapshot }
        var filtered = snapshot
        filtered.windows = snapshot.windows.compactMap(windowSnapshotForRestore)
        return filtered.windows.isEmpty ? nil : filtered
    }

    func windowSnapshotForRestore(_ snapshot: SessionWindowSnapshot) -> SessionWindowSnapshot? {
        guard !restoreTerminalSessions else { return snapshot }
        var filtered = snapshot
        filtered.tabManager = tabManagerSnapshotForRestore(snapshot.tabManager)
        filtered.dock = splitContainerSnapshotForRestore(
            snapshot.dock,
            retainedWorkspaceIDs: Set(filtered.tabManager.workspaces.compactMap(\.workspaceId))
        )
        guard !filtered.tabManager.workspaces.isEmpty || filtered.dock != nil else {
            return nil
        }
        return filtered
    }

    func tabManagerSnapshotForRestore(
        _ snapshot: SessionTabManagerSnapshot
    ) -> SessionTabManagerSnapshot {
        guard !restoreTerminalSessions else { return snapshot }

        let retained = snapshot.workspaces.enumerated().filter {
            !workspaceContainsTerminalSurface($0.element)
        }
        var filtered = snapshot
        filtered.workspaces = retained.map(\.element)
        filtered.selectedWorkspaceIndex = snapshot.selectedWorkspaceIndex.flatMap { index in
            retained.firstIndex { $0.offset == index }
        }
        filtered.workspaceGroups = filteredWorkspaceGroups(
            snapshot.workspaceGroups,
            originalWorkspaces: snapshot.workspaces,
            retainedWorkspaces: filtered.workspaces,
            retainedOriginalOffsets: retained.map(\.offset)
        )
        return filtered
    }

    private func workspaceContainsTerminalSurface(_ snapshot: SessionWorkspaceSnapshot) -> Bool {
        snapshot.panels.contains(where: panelContainsTerminalSurface)
            || snapshot.dock?.panels.contains(where: panelContainsTerminalSurface) == true
    }

    private func panelContainsTerminalSurface(_ snapshot: SessionPanelSnapshot) -> Bool {
        snapshot.type == .terminal || snapshot.terminal != nil
    }

    private func filteredWorkspaceGroups(
        _ groups: [SessionWorkspaceGroupSnapshot]?,
        originalWorkspaces: [SessionWorkspaceSnapshot],
        retainedWorkspaces: [SessionWorkspaceSnapshot],
        retainedOriginalOffsets: [Int]
    ) -> [SessionWorkspaceGroupSnapshot]? {
        guard let groups else { return nil }
        let filtered = groups.compactMap { group -> SessionWorkspaceGroupSnapshot? in
            let originalMembers = originalWorkspaces.enumerated().filter {
                $0.element.groupId == group.id
            }
            let retainedMembers = retainedWorkspaces.enumerated().compactMap {
                (entry: (offset: Int, element: SessionWorkspaceSnapshot))
                    -> (offset: Int, element: SessionWorkspaceSnapshot)? in
                let index = entry.offset
                let workspace = entry.element
                guard workspace.groupId == group.id else { return nil }
                let originalOffset = retainedOriginalOffsets.indices.contains(index)
                    ? retainedOriginalOffsets[index]
                    : index
                return (offset: originalOffset, element: workspace)
            }
            guard !retainedMembers.isEmpty else { return nil }

            let anchorOriginalOffset = group.anchorMemberIndex.flatMap { index in
                originalMembers.indices.contains(index) ? originalMembers[index].offset : nil
            }
            let anchorIndex = retainedMembers.firstIndex { member in
                member.offset == anchorOriginalOffset
            } ?? retainedMembers.firstIndex { member in
                member.element.workspaceId == group.anchorWorkspaceId
            } ?? 0

            var filteredGroup = group
            filteredGroup.anchorMemberIndex = anchorIndex
            filteredGroup.anchorWorkspaceId = retainedMembers[anchorIndex].element.workspaceId
            return filteredGroup
        }
        return filtered.isEmpty ? nil : filtered
    }

    private func splitContainerSnapshotForRestore(
        _ snapshot: SessionSplitContainerSnapshot?,
        retainedWorkspaceIDs: Set<UUID>
    ) -> SessionSplitContainerSnapshot? {
        guard let snapshot else { return nil }
        let retainedPanels = snapshot.panels.filter { !panelContainsTerminalSurface($0) }
        guard !retainedPanels.isEmpty else { return nil }

        var filtered = snapshot
        filtered.panels = retainedPanels
        let retainedPanelIDs = Set(retainedPanels.map(\.id))
        filtered.focusedPanelId = snapshot.focusedPanelId.flatMap {
            retainedPanelIDs.contains($0) ? $0 : retainedPanels.first?.id
        }
        filtered.layout = filteredLayout(
            snapshot.layout,
            retaining: retainedPanelIDs
        ) ?? .pane(
            SessionPaneLayoutSnapshot(
                panelIds: retainedPanels.map(\.id),
                selectedPanelId: retainedPanels.first?.id
            )
        )
        if let sourceWorkspaceIds = snapshot.sourceWorkspaceIdsByPanelId {
            filtered.sourceWorkspaceIdsByPanelId = sourceWorkspaceIds.filter {
                retainedPanelIDs.contains($0.key) && retainedWorkspaceIDs.contains($0.value)
            }
        }
        return filtered
    }

    private func filteredLayout(
        _ layout: SessionWorkspaceLayoutSnapshot,
        retaining panelIDs: Set<UUID>
    ) -> SessionWorkspaceLayoutSnapshot? {
        switch layout {
        case .pane(let pane):
            let retainedIDs = pane.panelIds.filter { panelIDs.contains($0) }
            guard !retainedIDs.isEmpty else { return nil }
            return .pane(
                SessionPaneLayoutSnapshot(
                    panelIds: retainedIDs,
                    selectedPanelId: pane.selectedPanelId.flatMap {
                        panelIDs.contains($0) ? $0 : retainedIDs.first
                    },
                    isFullWidthTabMode: pane.isFullWidthTabMode
                )
            )
        case .split(let split):
            let first = filteredLayout(split.first, retaining: panelIDs)
            let second = filteredLayout(split.second, retaining: panelIDs)
            switch (first, second) {
            case let (first?, second?):
                return .split(
                    SessionSplitLayoutSnapshot(
                        orientation: split.orientation,
                        dividerPosition: split.dividerPosition,
                        first: first,
                        second: second
                    )
                )
            case let (first?, nil):
                return first
            case let (nil, second?):
                return second
            case (nil, nil):
                return nil
            }
        }
    }
}
