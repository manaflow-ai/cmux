import CmuxMobileShellModel

/// Synchronous input-keyed cache for grouped workspace list projection.
///
/// This is deliberately a non-observable reference type: SwiftUI body updates
/// may read and update it without publishing another invalidation. Full value
/// inputs are retained so any rendered workspace or group field, input order,
/// or sort-mode change rebuilds the projection before that body returns.
@MainActor
final class WorkspaceListGroupedProjectionCache {
    private struct Input: Equatable {
        let workspaces: [MobileWorkspacePreview]
        let groups: [MobileWorkspaceGroupPreview]
        let appliesRecencySort: Bool
    }

    private var input: Input?
    private var projectedItems: [MobileWorkspaceListItem] = []

    func items(
        workspaces: [MobileWorkspacePreview],
        groups: [MobileWorkspaceGroupPreview],
        appliesRecencySort: Bool
    ) -> [MobileWorkspaceListItem] {
        let input = Input(
            workspaces: workspaces,
            groups: groups,
            appliesRecencySort: appliesRecencySort
        )
        if self.input == input {
            return projectedItems
        }

        let projectedItems = appliesRecencySort
            ? MobileWorkspaceRecencyOrder().groupedDisplayItems(workspaces, groups: groups)
            : MobileWorkspaceListItem.items(workspaces: workspaces, groups: groups)
        self.input = input
        self.projectedItems = projectedItems
        return projectedItems
    }
}
