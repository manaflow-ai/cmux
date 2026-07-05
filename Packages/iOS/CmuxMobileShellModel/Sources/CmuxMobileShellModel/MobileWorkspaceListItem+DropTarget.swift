/// Drop-target helpers derived from rendered list-item snapshots.
public extension MobileWorkspaceListItem {
    /// Resolves a `List` insertion index into a workspace drop target.
    ///
    /// The mapping is intentionally conservative around group headers. Gaps that
    /// sit on the far side of a header boundary resolve to `nil` rather than
    /// manufacturing a workspace-relative target across the header.
    ///
    /// - Parameters:
    ///   - items: The rendered workspace list snapshot.
    ///   - index: The `List` insertion index reported by SwiftUI.
    /// - Returns: A workspace-relative drop target, or `nil` for an ambiguous gap.
    static func insertionDropTarget(
        items: [MobileWorkspaceListItem],
        index: Int
    ) -> MobileWorkspaceDropTarget? {
        let boundedIndex = min(max(index, items.startIndex), items.endIndex)
        let previousItem = boundedIndex > items.startIndex ? items[items.index(before: boundedIndex)] : nil
        let nextItem = boundedIndex < items.endIndex ? items[boundedIndex] : nil

        switch (previousItem, nextItem) {
        case (.some(.groupHeader), .some(.groupHeader)),
            (.none, .some(.groupHeader)),
            (.some(.groupHeader), .none),
            (.some(.workspace), .some(.groupHeader)):
            return nil
        case (_, .some(.workspace(let workspace, _))):
            return .beforeWorkspace(workspace.id)
        case (.some(.workspace(let workspace, _)), _):
            return .afterWorkspace(workspace.id)
        default:
            return nil
        }
    }
}
