public import Foundation

/// Everything the sidebar needs to render one filter query's result.
///
/// The outcome deliberately does not reorder rows. A sidebar is a spatial
/// surface: users reach for a workspace by where it sits, and re-sorting by
/// score on every keystroke destroys that. Rows are hidden, never moved, and
/// ``bestMatchWorkspaceId`` carries the ranking separately so Return can still
/// jump to the strongest hit.
public struct SidebarFilterOutcome: Sendable, Equatable {
    /// Whether a query was active at all.
    ///
    /// `false` means the filter is off and every row renders untouched; callers
    /// use this to skip filtering work entirely rather than comparing sets.
    public let isFiltering: Bool
    /// Workspaces whose rows survive the filter, including group anchors kept
    /// only to give a surviving member its header.
    public let visibleWorkspaceIds: Set<UUID>
    /// Groups that must render expanded so their matching members are reachable.
    ///
    /// Transient: the filter never writes a group's persisted collapse state,
    /// so clearing the query restores exactly the shape the user had.
    public let expandedGroupIds: Set<UUID>
    /// Match detail per workspace, for highlighting.
    public let matchesByWorkspaceId: [UUID: SidebarFilterMatch]
    /// Matching workspaces in model order, for arrow-key navigation.
    public let orderedMatchWorkspaceIds: [UUID]
    /// The highest-scoring workspace, for Return.
    public let bestMatchWorkspaceId: UUID?

    /// The outcome for an inactive filter: everything visible, nothing matched.
    public static let inactive = SidebarFilterOutcome(
        isFiltering: false,
        visibleWorkspaceIds: [],
        expandedGroupIds: [],
        matchesByWorkspaceId: [:],
        orderedMatchWorkspaceIds: [],
        bestMatchWorkspaceId: nil
    )

    /// Whether the query matched nothing, so the sidebar should show its empty
    /// state instead of a blank list.
    public var isEmptyResult: Bool {
        isFiltering && orderedMatchWorkspaceIds.isEmpty
    }

    /// Whether the row for `workspaceId` should render.
    ///
    /// - Parameter workspaceId: The workspace whose row is being placed.
    /// - Returns: `true` when the filter is off or the workspace survived it.
    public func includesWorkspace(_ workspaceId: UUID) -> Bool {
        guard isFiltering else { return true }
        return visibleWorkspaceIds.contains(workspaceId)
    }

    /// Whether `groupId` should render expanded regardless of its stored
    /// collapse state.
    ///
    /// - Parameter groupId: The group being placed.
    /// - Returns: `true` only while a filter is forcing the group open.
    public func forcesGroupExpanded(_ groupId: UUID) -> Bool {
        isFiltering && expandedGroupIds.contains(groupId)
    }

    /// Creates an outcome.
    public init(
        isFiltering: Bool,
        visibleWorkspaceIds: Set<UUID>,
        expandedGroupIds: Set<UUID>,
        matchesByWorkspaceId: [UUID: SidebarFilterMatch],
        orderedMatchWorkspaceIds: [UUID],
        bestMatchWorkspaceId: UUID?
    ) {
        self.isFiltering = isFiltering
        self.visibleWorkspaceIds = visibleWorkspaceIds
        self.expandedGroupIds = expandedGroupIds
        self.matchesByWorkspaceId = matchesByWorkspaceId
        self.orderedMatchWorkspaceIds = orderedMatchWorkspaceIds
        self.bestMatchWorkspaceId = bestMatchWorkspaceId
    }
}
