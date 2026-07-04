public import Foundation

/// Value object deciding which workspaces stay mounted to minimize layer-tree
/// traversal. Operates only on workspace UUIDs, ordering, and pinning flags;
/// holds no state and touches no UI. Construct it with the current mount state
/// and read ``mountedWorkspaceIds``.
public struct WorkspaceMountPlan: Equatable {
    // Keep only the selected workspace mounted to minimize layer-tree traversal.
    public static let maxMountedWorkspaces = 1
    // During workspace cycling, keep only a minimal handoff pair (selected + retiring).
    public static let maxMountedWorkspacesDuringCycle = 2

    private let current: [UUID]
    private let selected: UUID?
    private let pinnedIds: Set<UUID>
    private let orderedTabIds: [UUID]
    private let activeWorkspaceIds: Set<UUID>
    private let isCycleHot: Bool
    private let maxMounted: Int

    /// Creates a mount plan from workspace order, liveness, and priority inputs.
    ///
    /// - Parameters:
    ///   - current: Workspace ids currently mounted, in priority order.
    ///   - selected: The selected workspace id, if any.
    ///   - pinnedIds: Workspace ids that must stay mounted for handoff or background work.
    ///   - orderedTabIds: Workspace ids in sidebar order.
    ///   - activeWorkspaceIds: Authoritative workspace ids that still exist. Defaults to `orderedTabIds`.
    ///   - isCycleHot: Whether workspace cycling is currently in its hot handoff window.
    ///   - maxMounted: Maximum number of workspace ids to retain.
    public init(
        current: [UUID],
        selected: UUID?,
        pinnedIds: Set<UUID>,
        orderedTabIds: [UUID],
        activeWorkspaceIds: Set<UUID>? = nil,
        isCycleHot: Bool,
        maxMounted: Int
    ) {
        self.current = current
        self.selected = selected
        self.pinnedIds = pinnedIds
        self.orderedTabIds = orderedTabIds
        self.activeWorkspaceIds = activeWorkspaceIds ?? Set(orderedTabIds)
        self.isCycleHot = isCycleHot
        self.maxMounted = maxMounted
    }

    /// The workspace ids that should remain mounted, in priority order.
    public var mountedWorkspaceIds: [UUID] {
        let existing = Set(orderedTabIds)
        let clampedMax = max(1, maxMounted)
        var ordered = current.filter { existing.contains($0) && activeWorkspaceIds.contains($0) }

        // Session restore can briefly publish an ordered-tab snapshot that omits
        // the selected workspace; keep it sticky only when liveness confirms it.
        let shouldKeepSelectedMounted = selected.map { activeWorkspaceIds.contains($0) } ?? false
        if let selected, shouldKeepSelectedMounted {
            ordered.removeAll { $0 == selected }
            ordered.insert(selected, at: 0)
        }

        if isCycleHot, let selected, shouldKeepSelectedMounted {
            let warmIds = Self.cycleWarmIds(selected: selected, orderedTabIds: orderedTabIds)
            for id in warmIds.reversed() {
                ordered.removeAll { $0 == id }
                ordered.insert(id, at: 0)
            }
        }

        if isCycleHot,
           pinnedIds.isEmpty,
           let selected,
           shouldKeepSelectedMounted {
            ordered.removeAll { $0 != selected }
        }

        // Ensure pinned ids (retiring handoff workspaces) are always retained at highest priority.
        // This runs after warming to prevent neighbor warming from evicting the retiring workspace.
        let orderIndexByWorkspaceId = Dictionary(
            orderedTabIds.enumerated().map { index, workspaceId in
                (workspaceId, index)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let prioritizedPinnedIds = pinnedIds
            .filter { activeWorkspaceIds.contains($0) && $0 != selected }
            .sorted { lhs, rhs in
                let lhsIndex = orderIndexByWorkspaceId[lhs] ?? .max
                let rhsIndex = orderIndexByWorkspaceId[rhs] ?? .max
                return lhsIndex < rhsIndex
            }
        if let selected, shouldKeepSelectedMounted {
            ordered.removeAll { $0 == selected }
            ordered.insert(selected, at: 0)
        }
        var pinnedInsertionIndex = shouldKeepSelectedMounted ? 1 : 0
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

    private static func cycleWarmIds(selected: UUID, orderedTabIds: [UUID]) -> [UUID] {
        guard orderedTabIds.contains(selected) else { return [selected] }
        // Keep warming focused to the selected workspace. Retiring/target workspaces are
        // pinned by handoff logic, so warming adjacent neighbors here just adds layout work.
        return [selected]
    }
}
