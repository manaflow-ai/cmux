public import Foundation

/// Orders workspace identifiers for the Go to Workspace switcher.
public struct CommandPaletteWorkspaceOrdering: Sendable {
    /// The source of the switcher's workspace order.
    public enum Mode: String, Sendable {
        /// Preserve the sidebar order, with the selected workspace first.
        case sidebar
        /// Put recently focused workspaces first and the selected workspace last.
        case recent
    }

    /// Creates a workspace ordering policy.
    public init() {}

    /// Returns a stable, de-duplicated workspace order.
    public func orderedWorkspaceIDs(
        sidebarIDs: [UUID],
        selectedID: UUID?,
        recentIDs: [UUID],
        mode: Mode
    ) -> [UUID] {
        let sidebarIDs = Self.unique(sidebarIDs)
        guard mode == .recent else {
            return Self.selectedFirst(sidebarIDs, selectedID: selectedID)
        }

        // The recency mode is intentionally covered by the regression test
        // before this implementation is filled in.
        return Self.selectedFirst(sidebarIDs, selectedID: selectedID)
    }

    private static func selectedFirst(_ ids: [UUID], selectedID: UUID?) -> [UUID] {
        guard let selectedID,
              let selectedIndex = ids.firstIndex(of: selectedID) else {
            return ids
        }
        var result = ids
        result.remove(at: selectedIndex)
        result.insert(selectedID, at: 0)
        return result
    }

    private static func unique(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }
}
