import CoreGraphics

/// A single whole-content height measurement of the sidebar workspace rows,
/// keyed by the workspace row identity that produced it.
///
/// The sidebar sizes the empty drop/tap area below the last row to the
/// remaining viewport (`SidebarWorkspaceScrollLayout.emptyAreaHeight`) from
/// one measurement of the laid-out rows. Keying by `workspaceIds` lets a stale
/// measurement be ignored after rows are added, removed, or reordered, and
/// `isEquivalent(to:tolerance:)` dedupes sub-pixel height jitter so constant
/// agent-driven row re-renders do not write `@State` and re-feed a
/// preference/layout transaction cycle
/// (the https://github.com/manaflow-ai/cmux/issues/2586 class of livelock).
struct SidebarWorkspaceRowsMeasurement<ID: Equatable>: Equatable {
    let workspaceIds: [ID]
    let rowsHeight: CGFloat

    nonisolated func rowsHeight(for currentWorkspaceIds: [ID]) -> CGFloat? {
        guard workspaceIds == currentWorkspaceIds else { return nil }
        return max(0, rowsHeight)
    }

    nonisolated func isEquivalent(
        to other: SidebarWorkspaceRowsMeasurement<ID>,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        workspaceIds == other.workspaceIds && abs(rowsHeight - other.rowsHeight) <= tolerance
    }
}
