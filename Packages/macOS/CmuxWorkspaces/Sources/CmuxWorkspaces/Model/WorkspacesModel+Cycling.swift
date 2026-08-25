public import Foundation

extension WorkspacesModel {
    /// Resolves the workspace selected by a cycle action without mutating model state.
    ///
    /// Group-member cycling excludes the group's anchor because the sidebar renders
    /// that workspace as the group header. When the focused workspace is ungrouped,
    /// group-member cycling falls back to the window-wide order.
    ///
    /// ```swift
    /// let destination = model.cycleDestination(
    ///     from: model.selectedTabId,
    ///     direction: .next,
    ///     scope: .focusedGroupMembers
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - currentWorkspaceId: The currently selected workspace identifier.
    ///   - direction: The direction in which to advance through the resolved order.
    ///   - scope: The workspace set that participates in the cycle.
    /// - Returns: The destination workspace identifier, or `nil` when the current
    ///   workspace is missing or the resolved scope has no selectable workspace.
    public func cycleDestination(
        from currentWorkspaceId: UUID?,
        direction: WorkspaceCycleDirection,
        scope: WorkspaceCycleScope
    ) -> UUID? {
        guard let currentWorkspaceId,
              let currentWorkspace = tabs.first(where: { $0.id == currentWorkspaceId }) else {
            return nil
        }

        let candidates: [Tab]
        switch scope {
        case .window:
            candidates = tabs
        case .visibleWorkspaceRows:
            let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
            candidates = tabs.filter { tab in
                guard let groupId = tab.groupId else {
                    return true
                }
                guard let group = groupsById[groupId] else { return true }
                return tab.id != group.anchorWorkspaceId && !group.isCollapsed
            }
        case .focusedGroupMembers:
            if let groupId = currentWorkspace.groupId,
               let group = workspaceGroups.first(where: { $0.id == groupId }) {
                candidates = tabs.filter {
                    $0.groupId == groupId && $0.id != group.anchorWorkspaceId
                }
            } else {
                candidates = tabs
            }
        }

        if case .visibleWorkspaceRows = scope,
           !candidates.contains(where: { $0.id == currentWorkspaceId }) {
            return nearestCycleDestination(
                from: currentWorkspaceId,
                direction: direction,
                candidates: candidates
            )
        }
        return cycleDestination(from: currentWorkspaceId, direction: direction, candidates: candidates)
    }

    /// Advances through an already-filtered candidate order, wrapping at either end.
    private func cycleDestination(
        from currentWorkspaceId: UUID,
        direction: WorkspaceCycleDirection,
        candidates: [Tab]
    ) -> UUID? {
        guard !candidates.isEmpty else { return nil }
        guard let currentIndex = candidates.firstIndex(where: { $0.id == currentWorkspaceId }) else {
            return switch direction {
            case .next: candidates.first?.id
            case .previous: candidates.last?.id
            }
        }

        let destinationIndex = switch direction {
        case .next: (currentIndex + 1) % candidates.count
        case .previous: (currentIndex - 1 + candidates.count) % candidates.count
        }
        return candidates[destinationIndex].id
    }

    /// Finds the nearest eligible tab when the current workspace row is hidden.
    private func nearestCycleDestination(
        from currentWorkspaceId: UUID,
        direction: WorkspaceCycleDirection,
        candidates: [Tab]
    ) -> UUID? {
        guard !candidates.isEmpty,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentWorkspaceId }) else {
            return nil
        }
        let candidateIds = Set(candidates.map(\.id))
        for offset in 1...tabs.count {
            let index = switch direction {
            case .next: (currentIndex + offset) % tabs.count
            case .previous: (currentIndex - offset + tabs.count) % tabs.count
            }
            if candidateIds.contains(tabs[index].id) {
                return tabs[index].id
            }
        }
        return nil
    }
}
