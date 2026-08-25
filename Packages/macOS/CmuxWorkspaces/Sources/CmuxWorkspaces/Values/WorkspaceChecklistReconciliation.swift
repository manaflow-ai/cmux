import Foundation

extension Array where Element == WorkspaceChecklistItem {
    /// Atomically replaces the checklist items owned by one external source.
    ///
    /// Items without the matching owner remain unchanged. Existing owned
    /// items omitted from `items` are removed, including tasks deleted from
    /// the source snapshot. Incoming IDs may not collide with an unrelated
    /// item, and the combined checklist must remain within the shared cap.
    ///
    /// - Parameters:
    ///   - ownerID: The stable, source-scoped ownership key.
    ///   - items: The complete desired snapshot for that owner.
    /// - Returns: The combined checklist, or the rejection reason. A failure
    ///   leaves the original checklist unchanged.
    @discardableResult
    public mutating func reconcileChecklist(
        ownerID: String,
        with items: [WorkspaceChecklistReplacementItem]
    ) -> Result<[WorkspaceChecklistItem], WorkspaceChecklistReplaceError> {
        var existingIDs = Set<UUID>()
        for (index, existing) in enumerated() {
            guard existingIDs.insert(existing.id).inserted else {
                return .failure(.duplicateId(index: index))
            }
        }

        let unrelatedItems = filter { $0.ownerID != ownerID }
        guard unrelatedItems.count + items.count <= WorkspaceChecklistItem.maxChecklistItems else {
            return .failure(.tooManyItems(count: unrelatedItems.count + items.count))
        }

        let unrelatedIDs = Set(unrelatedItems.map(\.id))
        if let collisionIndex = items.firstIndex(where: { item in
            item.id.map(unrelatedIDs.contains) == true
        }) {
            return .failure(.duplicateId(index: collisionIndex))
        }

        var ownedItems = filter { $0.ownerID == ownerID }
        switch ownedItems.replaceChecklist(with: items) {
        case .failure(let error):
            return .failure(error)
        case .success:
            for index in ownedItems.indices {
                ownedItems[index].ownerID = ownerID
            }
            // Rebuild from the original sequence so unrelated rows retain
            // their relative order. Replace the owner block at its first
            // original slot, then restore the checklist's stable
            // uncompleted-before-completed partition without sorting either
            // partition.
            var combined: [WorkspaceChecklistItem] = []
            combined.reserveCapacity(unrelatedItems.count + ownedItems.count)
            var insertedOwnerItems = false
            for existing in self {
                if existing.ownerID == ownerID {
                    if !insertedOwnerItems {
                        combined.append(contentsOf: ownedItems)
                        insertedOwnerItems = true
                    }
                } else {
                    combined.append(existing)
                }
            }
            if !insertedOwnerItems {
                combined.append(contentsOf: ownedItems)
            }
            let uncompleted = combined.filter { $0.state != .completed }
            let completed = combined.filter { $0.state == .completed }
            let normalized = uncompleted + completed
            self = normalized
            return .success(normalized)
        }
    }
}
