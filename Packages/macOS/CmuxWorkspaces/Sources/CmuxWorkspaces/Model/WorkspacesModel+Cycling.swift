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
        case .focusedGroupMembers:
            if let groupId = currentWorkspace.groupId,
               let group = workspaceGroups.first(where: { $0.id == groupId }) {
                candidates = tabs.filter {
                    $0.groupId == groupId && $0.id != group.liveAnchorWorkspaceId
                }
            } else {
                candidates = tabs
            }
        }

        return cycleDestination(
            from: currentWorkspaceId,
            direction: direction,
            candidates: candidates
        )
    }

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
}
