/// The empty state a workspace-list surface should show for its current
/// workspace count, search query, and filter.
public enum MobileWorkspaceListEmptyState: Equatable, Sendable {
    /// The Mac reported no workspaces at all.
    case noWorkspaces
    /// The user has a non-empty search query and no visible rows match it.
    case noSearchResults
    /// The current filter hides every workspace.
    case filterNoMatches(MobileWorkspaceListFilter)

    /// Returns the empty state for a workspace-list snapshot, or `nil` when at
    /// least one visible row should render. Keeping this decision outside
    /// SwiftUI makes the flat workspace list and device tree easier to keep
    /// aligned.
    ///
    /// - Parameters:
    ///   - workspaceCount: Total workspace rows before search/filter narrowing.
    ///   - visibleWorkspaceCount: Rows visible after search/filter narrowing.
    ///   - queryMatchedWorkspaceCount: Rows that match the search query before
    ///     filter narrowing.
    ///   - trimmedQuery: Search query after whitespace trimming.
    ///   - filter: Active workspace filter.
    public static func state(
        workspaceCount: Int,
        visibleWorkspaceCount: Int,
        queryMatchedWorkspaceCount: Int,
        trimmedQuery: String,
        filter: MobileWorkspaceListFilter
    ) -> MobileWorkspaceListEmptyState? {
        if workspaceCount == 0 {
            return .noWorkspaces
        }
        if visibleWorkspaceCount > 0 {
            return nil
        }
        if !trimmedQuery.isEmpty && filter.isActive && queryMatchedWorkspaceCount > 0 {
            return .filterNoMatches(filter)
        }
        if !trimmedQuery.isEmpty {
            return .noSearchResults
        }
        if filter.isActive {
            return .filterNoMatches(filter)
        }
        return nil
    }
}
