public import Foundation

extension Array where Element == MobileWorkspaceListItem {
    /// Resolves a SwiftUI `List` move into a Mac-facing workspace move intent.
    ///
    /// The `destination` index is the pre-removal index space reported by
    /// `ForEach.onMove`. Group headers move their anchor workspace, synthetic
    /// footers are never movable, and identity/no-op landings resolve to `nil`.
    ///
    /// - Parameters:
    ///   - workspaces: The full workspace order from the Mac.
    ///   - groups: The group snapshots from the Mac.
    ///   - sourceOffsets: The moved row offsets from SwiftUI.
    ///   - destination: The destination offset from SwiftUI, in pre-removal space.
    /// - Returns: A workspace move intent, or `nil` when the move should not fire.
    public func moveIntent(
        workspaces: [MobileWorkspacePreview],
        groups: [MobileWorkspaceGroupPreview],
        sourceOffsets: IndexSet,
        destination: Int
    ) -> MobileWorkspaceMoveIntent? {
        MobileWorkspaceListMoveIntentResolver(
            items: self,
            workspaces: workspaces,
            groups: groups
        ).moveIntent(sourceOffsets: sourceOffsets, destination: destination)
    }
}

extension Array where Element == MobileWorkspacePreview {
    /// Returns the workspace order after optimistically applying a move intent.
    ///
    /// The returned order is used as the authoritative-order stand-in while the
    /// Mac move RPC is pending.
    ///
    /// - Parameters:
    ///   - intent: The move intent derived from the rendered list snapshot.
    ///   - movedWorkspaceID: The dragged workspace, or a moved group's anchor workspace.
    ///   - groups: The group snapshots used to preserve group membership and ordering.
    /// - Returns: A workspace snapshot with the move applied.
    public func applyingWorkspaceMoveIntent(
        _ intent: MobileWorkspaceMoveIntent,
        movedWorkspaceID: MobileWorkspacePreview.ID,
        groups: [MobileWorkspaceGroupPreview]
    ) -> [MobileWorkspacePreview] {
        MobileWorkspaceOrderMoveApplier(workspaces: self, groups: groups)
            .applying(intent, movedWorkspaceID: movedWorkspaceID)
    }
}
