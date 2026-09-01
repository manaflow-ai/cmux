import Foundation
import CmuxWorkspaces

/// App-side adapter that applies the terminal-session restore preference at
/// every persisted-session boundary. The scalable workspace/group planning
/// algorithm is owned by ``TerminalSessionRestorePlanner`` in the
/// `CmuxWorkspaces` package; this type only bridges the app's wire-format DTOs
/// and filters their AppKit-specific dock layout. Explicit closed-item restores
/// opt out at their call site.
struct SessionTerminalRestorePolicy: Sendable {
    let restoreTerminalSessions: Bool

    /// Creates a policy from an already-resolved preference value.
    init(restoreTerminalSessions: Bool) {
        self.restoreTerminalSessions = restoreTerminalSessions
    }

    /// Captures the effective preference from an injected settings owner.
    init(settings: TerminalSessionRestoreSettings) {
        self.init(restoreTerminalSessions: settings.isEnabled)
    }

    /// Captures the effective preference from the supplied defaults store.
    init(defaults: UserDefaults = .standard) {
        self.init(settings: TerminalSessionRestoreSettings(defaults: defaults))
    }

    /// Filters an app snapshot once, preserving browser-only windows and
    /// returning `nil` when no restorable content remains.
    func appSnapshotForRestore(_ snapshot: AppSessionSnapshot) -> AppSessionSnapshot? {
        guard !restoreTerminalSessions else { return snapshot }
        var filtered = snapshot
        filtered.windows = snapshot.windows.compactMap(windowSnapshotForRestore)
        return filtered.windows.isEmpty ? nil : filtered
    }

    /// Filters one window snapshot using this policy's captured value.
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

    /// Filters workspace and dock snapshots without rereading UserDefaults.
    func tabManagerSnapshotForRestore(
        _ snapshot: SessionTabManagerSnapshot
    ) -> SessionTabManagerSnapshot {
        guard !restoreTerminalSessions else { return snapshot }

        let planner = TerminalSessionRestorePlanner(
            restoreTerminalSessions: restoreTerminalSessions
        )
        let plan = planner.planWorkspaces(
            snapshot.workspaces.map {
                TerminalSessionRestoreWorkspaceDescriptor(
                    workspaceID: $0.workspaceId,
                    groupID: $0.groupId,
                    containsTerminalSurface: workspaceContainsTerminalSurface($0)
                )
            },
            selectedWorkspaceIndex: snapshot.selectedWorkspaceIndex,
            groups: snapshot.workspaceGroups?.map {
                TerminalSessionRestoreGroupDescriptor(
                    id: $0.id,
                    anchorMemberIndex: $0.anchorMemberIndex,
                    anchorWorkspaceID: $0.anchorWorkspaceId,
                    // TabManager keeps every pinned group durable when all of
                    // its members are filtered, including legacy snapshots
                    // that omitted `anchorIsEmpty`.
                    preserveWhenEmpty: $0.isPinned == true
                )
            }
        )
        var filtered = snapshot
        filtered.workspaces = plan.retainedOriginalOffsets.map { snapshot.workspaces[$0] }
        filtered.selectedWorkspaceIndex = plan.selectedWorkspaceIndex
        var groupPlansByID: [UUID: TerminalSessionRestoreGroupPlan] = [:]
        for groupPlan in plan.groups ?? [] {
            // Keep the first plan for a duplicate/corrupt group id, matching
            // TabManager's de-duplication behavior during restore.
            groupPlansByID[groupPlan.id] = groupPlansByID[groupPlan.id] ?? groupPlan
        }
        if let groups = snapshot.workspaceGroups {
            let filteredGroups = groups.compactMap { group -> SessionWorkspaceGroupSnapshot? in
                guard let groupPlan = groupPlansByID[group.id] else { return nil }
                var filteredGroup = group
                filteredGroup.anchorMemberIndex = groupPlan.anchorMemberIndex
                filteredGroup.anchorWorkspaceId = groupPlan.anchorWorkspaceID
                return filteredGroup
            }
            filtered.workspaceGroups = filteredGroups.isEmpty ? nil : filteredGroups
        }
        return filtered
    }

    /// Reports whether a workspace's main or embedded Dock contains a terminal.
    private func workspaceContainsTerminalSurface(_ snapshot: SessionWorkspaceSnapshot) -> Bool {
        snapshot.panels.contains(where: panelContainsTerminalSurface)
            || snapshot.dock?.panels.contains(where: panelContainsTerminalSurface) == true
    }

    /// Reports whether a persisted panel represents a terminal surface.
    private func panelContainsTerminalSurface(_ snapshot: SessionPanelSnapshot) -> Bool {
        snapshot.type == .terminal || snapshot.terminal != nil
    }

    /// Filters a window or workspace Dock and repairs its source ownership map.
    private func splitContainerSnapshotForRestore(
        _ snapshot: SessionSplitContainerSnapshot?,
        retainedWorkspaceIDs: Set<UUID>
    ) -> SessionSplitContainerSnapshot? {
        guard let snapshot else { return nil }
        let planner = TerminalSessionRestorePlanner(
            restoreTerminalSessions: restoreTerminalSessions
        )
        guard let plan = planner.planContainer(
            panels: snapshot.panels.map {
                TerminalSessionRestorePanelDescriptor(
                    id: $0.id,
                    containsTerminalSurface: panelContainsTerminalSurface($0)
                )
            },
            focusedPanelID: snapshot.focusedPanelId,
            layout: terminalRestoreLayout(from: snapshot.layout)
        ) else {
            return nil
        }

        var filtered = snapshot
        let retainedPanelIDs = Set(plan.retainedPanelIDs)
        filtered.panels = snapshot.panels.filter {
            retainedPanelIDs.contains($0.id) && !panelContainsTerminalSurface($0)
        }
        filtered.focusedPanelId = plan.focusedPanelID
        filtered.layout = sessionLayout(from: plan.layout)
        if let sourceWorkspaceIds = snapshot.sourceWorkspaceIdsByPanelId {
            filtered.sourceWorkspaceIdsByPanelId = sourceWorkspaceIds.filter {
                retainedPanelIDs.contains($0.key) && retainedWorkspaceIDs.contains($0.value)
            }
        }
        return filtered
    }

    /// Converts the app layout DTO into the package planner's neutral tree.
    private func terminalRestoreLayout(
        from layout: SessionWorkspaceLayoutSnapshot
    ) -> TerminalSessionRestoreLayout {
        switch layout {
        case .pane(let pane):
            return .pane(
                panelIDs: pane.panelIds,
                selectedPanelID: pane.selectedPanelId,
                isFullWidthTabMode: pane.isFullWidthTabMode
            )
        case .split(let split):
            return .split(
                orientation: split.orientation == .horizontal ? .horizontal : .vertical,
                dividerPosition: split.dividerPosition,
                first: terminalRestoreLayout(from: split.first),
                second: terminalRestoreLayout(from: split.second)
            )
        }
    }

    /// Converts a neutral planner tree back into the app persistence DTO.
    private func sessionLayout(
        from layout: TerminalSessionRestoreLayout
    ) -> SessionWorkspaceLayoutSnapshot {
        switch layout {
        case let .pane(panelIDs, selectedPanelID, isFullWidthTabMode):
            return .pane(
                SessionPaneLayoutSnapshot(
                    panelIds: panelIDs,
                    selectedPanelId: selectedPanelID,
                    isFullWidthTabMode: isFullWidthTabMode
                )
            )
        case let .split(orientation, dividerPosition, first, second):
            return .split(
                SessionSplitLayoutSnapshot(
                    orientation: orientation == .horizontal ? .horizontal : .vertical,
                    dividerPosition: dividerPosition,
                    first: sessionLayout(from: first),
                    second: sessionLayout(from: second)
                )
            )
        }
    }
}
