public import Foundation

/// Value object deciding which workspaces stay mounted to minimize layer-tree
/// traversal. Operates only on workspace UUIDs, ordering, and pinning flags;
/// holds no state and touches no UI. Construct it with the current mount state
/// and read ``mountedWorkspaceIds``.
public struct WorkspaceMountPlan: Equatable {
    // Keep only the selected workspace mounted to minimize layer-tree traversal.
    public static let maxMountedWorkspaces = 1

    private let current: [UUID]
    private let selected: UUID?
    private let pinnedIds: Set<UUID>
    private let orderedTabIds: [UUID]
    private let maxMounted: Int

    public init(
        current: [UUID],
        selected: UUID?,
        pinnedIds: Set<UUID>,
        orderedTabIds: [UUID],
        maxMounted: Int
    ) {
        self.current = current
        self.selected = selected
        self.pinnedIds = pinnedIds
        self.orderedTabIds = orderedTabIds
        self.maxMounted = maxMounted
    }

    /// The workspace ids that should remain mounted, in priority order.
    public var mountedWorkspaceIds: [UUID] {
        let existing = Set(orderedTabIds)
        let clampedMax = max(1, maxMounted)
        var ordered = current.filter { existing.contains($0) }

        if let selected, existing.contains(selected) {
            ordered.removeAll { $0 == selected }
            ordered.insert(selected, at: 0)
        }

        // Ensure explicitly pinned background-prime/debug workspaces are
        // retained at highest priority behind the selected workspace.
        let prioritizedPinnedIds = pinnedIds
            .filter { existing.contains($0) && $0 != selected }
            .sorted { lhs, rhs in
                let lhsIndex = orderedTabIds.firstIndex(of: lhs) ?? .max
                let rhsIndex = orderedTabIds.firstIndex(of: rhs) ?? .max
                return lhsIndex < rhsIndex
            }
        if let selected, existing.contains(selected) {
            ordered.removeAll { $0 == selected }
            ordered.insert(selected, at: 0)
        }
        var pinnedInsertionIndex = (selected != nil) ? 1 : 0
        for pinnedId in prioritizedPinnedIds {
            ordered.removeAll { $0 == pinnedId }
            let insertionIndex = min(pinnedInsertionIndex, ordered.count)
            ordered.insert(pinnedId, at: insertionIndex)
            pinnedInsertionIndex += 1
        }

        if ordered.count > clampedMax {
            ordered.removeSubrange(clampedMax...)
        }

        return ordered
    }
}
