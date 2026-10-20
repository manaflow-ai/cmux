public import Foundation

/// Pure policy reconciling the sidebar's multi-workspace selection against the
/// live workspace list, and computing shift-click anchor indices. Operates only
/// on workspace UUIDs and indices; holds no state and touches no UI.
public struct SidebarWorkspaceSelectionSyncPolicy {
    public init() {}

    /// Filters a previous selection down to workspaces that still exist, falling
    /// back to the provided selected workspace when nothing survives.
    public func reconciledSelection(
        previousSelectionIds: Set<UUID>,
        liveWorkspaceIds: [UUID],
        fallbackSelectedWorkspaceId: UUID?
    ) -> Set<UUID> {
        let liveIdSet = Set(liveWorkspaceIds)
        let liveSelectionIds = previousSelectionIds.filter { liveIdSet.contains($0) }
        if !liveSelectionIds.isEmpty {
            return liveSelectionIds
        }
        if let fallbackSelectedWorkspaceId, liveIdSet.contains(fallbackSelectedWorkspaceId) {
            return [fallbackSelectedWorkspaceId]
        }
        return []
    }

    /// Index of the preferred (or first selected) workspace in the live list.
    public func anchorIndex(
        preferredWorkspaceId: UUID?,
        selectedWorkspaceIds: Set<UUID>,
        liveWorkspaceIds: [UUID]
    ) -> Int? {
        if let preferredWorkspaceId,
           selectedWorkspaceIds.contains(preferredWorkspaceId),
           let preferredIndex = liveWorkspaceIds.firstIndex(of: preferredWorkspaceId) {
            return preferredIndex
        }
        return liveWorkspaceIds.firstIndex { selectedWorkspaceIds.contains($0) }
    }

    /// Workspace id at an existing anchor index, if the index is still valid.
    public func anchorWorkspaceId(
        existingAnchorIndex: Int?,
        liveWorkspaceIds: [UUID]
    ) -> UUID? {
        guard let existingAnchorIndex,
              liveWorkspaceIds.indices.contains(existingAnchorIndex) else {
            return nil
        }
        return liveWorkspaceIds[existingAnchorIndex]
    }

    /// Anchor index to use for a shift-click range, deriving one from the
    /// current selection or focus when no anchor exists yet.
    public func shiftClickAnchorIndex(
        existingAnchorIndex: Int?,
        selectedWorkspaceIds: Set<UUID>,
        focusedWorkspaceId: UUID?,
        liveWorkspaceIds: [UUID]
    ) -> Int? {
        if let existingAnchorIndex,
           liveWorkspaceIds.indices.contains(existingAnchorIndex) {
            return existingAnchorIndex
        }
        if selectedWorkspaceIds.count == 1,
           let selectedWorkspaceId = selectedWorkspaceIds.first,
           let selectedIndex = liveWorkspaceIds.firstIndex(of: selectedWorkspaceId) {
            return selectedIndex
        }
        if let focusedWorkspaceId {
            return liveWorkspaceIds.firstIndex(of: focusedWorkspaceId)
        }
        return nil
    }

    /// Resulting anchor index after a workspace click (shift vs plain).
    public func anchorIndexAfterWorkspaceClick(
        isShiftClick: Bool,
        resolvedShiftAnchorIndex: Int?,
        clickedIndex: Int
    ) -> Int {
        isShiftClick ? (resolvedShiftAnchorIndex ?? clickedIndex) : clickedIndex
    }

    /// Anchor index to preserve after the workspace list is reordered.
    public func anchorIndexAfterWorkspaceReorder(
        preferredAnchorWorkspaceId: UUID?,
        selectedWorkspaceIds: Set<UUID>,
        focusedWorkspaceId: UUID?,
        liveWorkspaceIds: [UUID]
    ) -> Int? {
        if let preferredAnchorWorkspaceId,
           selectedWorkspaceIds.contains(preferredAnchorWorkspaceId),
           let anchorIndex = liveWorkspaceIds.firstIndex(of: preferredAnchorWorkspaceId) {
            return anchorIndex
        }
        return anchorIndex(
            preferredWorkspaceId: focusedWorkspaceId,
            selectedWorkspaceIds: selectedWorkspaceIds,
            liveWorkspaceIds: liveWorkspaceIds
        )
    }
}
