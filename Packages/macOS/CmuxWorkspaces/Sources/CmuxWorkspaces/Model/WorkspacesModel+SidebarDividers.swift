public import Foundation

// MARK: - Lightweight sidebar dividers

extension WorkspacesModel {
    /// Replaces every divider after validating it against the current sidebar
    /// topology. Host observers therefore receive only the normalized value.
    ///
    /// - Parameter newValue: The candidate divider placements to normalize.
    public func replaceSidebarDividers(_ newValue: [WorkspaceSidebarDivider]) {
        assignNormalizedSidebarDividers(normalizedSidebarDividers(newValue))
    }

    /// Returns only unique, non-boundary divider placements for the current
    /// top-level sidebar rows.
    private func normalizedSidebarDividers(
        _ dividers: [WorkspaceSidebarDivider]
    ) -> [WorkspaceSidebarDivider] {
        let topLevelIds = sidebarTopLevelWorkspaceIdsForSidebar()
        guard !topLevelIds.isEmpty else { return [] }
        let validAnchors = Set(topLevelIds.dropLast())
        var seenAnchors = Set<UUID>()
        return dividers.filter { divider in
            validAnchors.contains(divider.afterWorkspaceId)
                && seenAnchors.insert(divider.afterWorkspaceId).inserted
        }
    }

    /// Returns the top-level row ids in their current sidebar order.
    ///
    /// Group anchors represent their whole group; child workspaces are not
    /// returned as separate top-level rows. Durable empty group headers are
    /// included because they are real sidebar rows and can own a divider.
    public func sidebarTopLevelWorkspaceIdsForSidebar() -> [UUID] {
        sidebarTopLevelWorkspaceIdsIncludingEmptyGroups()
    }

    /// Resolves any workspace to the top-level row that represents it.
    public func sidebarTopLevelWorkspaceId(for workspaceId: UUID) -> UUID? {
        guard let tab = tabs.first(where: { $0.id == workspaceId }) else {
            // Header-only groups have no tab to resolve, but their stable
            // anchor identity is still a valid top-level row id.
            return workspaceGroups.contains { $0.anchorWorkspaceId == workspaceId }
                ? workspaceId
                : nil
        }
        if let groupId = tab.groupId,
           let group = workspaceGroups.first(where: { $0.id == groupId }) {
            return group.anchorWorkspaceId
        }
        return tab.id
    }

    /// Returns the divider anchored after `workspaceId`, if one exists.
    public func sidebarDivider(after workspaceId: UUID) -> WorkspaceSidebarDivider? {
        sidebarDividers.first { $0.afterWorkspaceId == workspaceId }
    }

    /// Returns whether a divider can be inserted after the given top-level row.
    public func canInsertSidebarDivider(after workspaceId: UUID) -> Bool {
        let topLevelIds = sidebarTopLevelWorkspaceIdsForSidebar()
        guard let index = topLevelIds.firstIndex(of: workspaceId),
              index < topLevelIds.count - 1,
              sidebarDividers.allSatisfy({ $0.afterWorkspaceId != workspaceId }) else {
            return false
        }
        return true
    }

    /// Returns whether an existing divider can occupy the requested gap.
    /// The current placement is accepted as a handled no-op; another divider
    /// already occupying the gap is rejected.
    public func canMoveSidebarDivider(id dividerId: UUID, after workspaceId: UUID) -> Bool {
        guard let divider = sidebarDividers.first(where: { $0.id == dividerId }) else {
            return false
        }
        if divider.afterWorkspaceId == workspaceId { return true }
        return canInsertSidebarDivider(after: workspaceId)
    }

    /// Returns whether a divider can be inserted immediately before a row.
    public func canInsertSidebarDivider(before workspaceId: UUID) -> Bool {
        let topLevelIds = sidebarTopLevelWorkspaceIdsForSidebar()
        guard let index = topLevelIds.firstIndex(of: workspaceId),
              index > 0 else {
            return false
        }
        return canInsertSidebarDivider(after: topLevelIds[index - 1])
    }

    /// Inserts one divider after a top-level row and returns its id.
    @discardableResult
    public func insertSidebarDivider(after workspaceId: UUID) -> UUID? {
        guard canInsertSidebarDivider(after: workspaceId) else { return nil }
        let divider = WorkspaceSidebarDivider(afterWorkspaceId: workspaceId)
        replaceSidebarDividers(sidebarDividers + [divider])
        return sidebarDividers.contains { $0.id == divider.id } ? divider.id : nil
    }

    /// Inserts one divider immediately before a top-level row and returns its id.
    @discardableResult
    public func insertSidebarDivider(before workspaceId: UUID) -> UUID? {
        let topLevelIds = sidebarTopLevelWorkspaceIdsForSidebar()
        guard let index = topLevelIds.firstIndex(of: workspaceId), index > 0 else {
            return nil
        }
        return insertSidebarDivider(after: topLevelIds[index - 1])
    }

    /// Adds a divider at the last legal interior gap in the sidebar.
    @discardableResult
    public func insertSidebarDividerAtEnd() -> UUID? {
        let occupiedAnchors = Set(sidebarDividers.map(\.afterWorkspaceId))
        guard let anchor = sidebarTopLevelWorkspaceIdsForSidebar()
            .dropLast()
            .reversed()
            .first(where: { !occupiedAnchors.contains($0) }) else {
            return nil
        }
        return insertSidebarDivider(after: anchor)
    }

    /// Moves a divider to the gap immediately after another top-level row.
    ///
    /// The mutation is rejected when the destination would be leading,
    /// trailing, or already occupied by another divider.
    @discardableResult
    public func moveSidebarDivider(id dividerId: UUID, after workspaceId: UUID) -> Bool {
        guard let index = sidebarDividers.firstIndex(where: { $0.id == dividerId }) else {
            return false
        }
        if sidebarDividers[index].afterWorkspaceId == workspaceId {
            return true
        }
        guard canMoveSidebarDivider(id: dividerId, after: workspaceId) else {
            return false
        }
        var updated = sidebarDividers
        updated[index].afterWorkspaceId = workspaceId
        replaceSidebarDividers(updated)
        return sidebarDividers.contains { $0.id == dividerId && $0.afterWorkspaceId == workspaceId }
    }

    /// Removes a divider. Returns `true` when an existing divider was removed.
    @discardableResult
    public func removeSidebarDivider(id dividerId: UUID) -> Bool {
        let oldCount = sidebarDividers.count
        let updated = sidebarDividers.filter { $0.id != dividerId }
        replaceSidebarDividers(updated)
        return oldCount != sidebarDividers.count
    }

    /// Drops stale/duplicate placements and keeps divider order deterministic.
    ///
    /// This is intentionally called after workspace/group lifecycle changes as
    /// well as after direct divider edits. A closed anchor therefore removes
    /// only its divider and never changes any workspace or group state.
    public func normalizeSidebarDividers() {
        let normalized = normalizedSidebarDividers(sidebarDividers)
        if normalized != sidebarDividers {
            assignNormalizedSidebarDividers(normalized)
        }
    }

    /// Computes the divider ids in the order they appear in the sidebar.
    public func sidebarDividerIdsInRenderOrder() -> [UUID] {
        let byAnchor = Dictionary(uniqueKeysWithValues: sidebarDividers.map {
            ($0.afterWorkspaceId, $0.id)
        })
        return sidebarTopLevelWorkspaceIdsForSidebar().compactMap { byAnchor[$0] }
    }

    /// Computes the order used by notification-driven "move to top" bumps.
    ///
    /// Dividers are treated as barriers: an unpinned workspace moves to the
    /// front of the unpinned tier in its current visual segment, while rows in
    /// every other segment keep their order. `nil` means the workspace is
    /// unknown or belongs to a pinned top-level row, matching the coordinator's
    /// existing no-op behavior for those cases.
    public func sidebarTopLevelWorkspaceIdsAfterNotificationMove(
        for workspaceId: UUID
    ) -> [UUID]? {
        let topLevelIds = sidebarTopLevelWorkspaceIdsForSidebar()
        let pinnedTopLevelIds = sidebarTopLevelPinnedWorkspaceIdsIncludingEmptyGroups()
        guard let topLevelId = sidebarTopLevelWorkspaceId(for: workspaceId),
              let currentIndex = topLevelIds.firstIndex(of: topLevelId),
              !pinnedTopLevelIds.contains(topLevelId) else {
            return nil
        }

        let dividerAnchors = Set(sidebarDividers.map(\.afterWorkspaceId))
        let dividerAnchorIndices = topLevelIds.indices.filter {
            dividerAnchors.contains(topLevelIds[$0])
        }
        let segmentStart = dividerAnchorIndices.last(where: { $0 < currentIndex }).map { $0 + 1 } ?? 0
        let segmentEnd = dividerAnchorIndices.first(where: { $0 >= currentIndex }).map { $0 + 1 } ?? topLevelIds.count
        let segmentIds = topLevelIds[segmentStart..<segmentEnd]
        let pinnedCount = segmentIds.reduce(into: 0) { count, id in
            if pinnedTopLevelIds.contains(id) {
                count += 1
            }
        }

        var result = topLevelIds
        let movedId = result.remove(at: currentIndex)
        result.insert(movedId, at: min(segmentStart + pinnedCount, result.count))
        return result
    }

}
