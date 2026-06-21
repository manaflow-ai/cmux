import CoreGraphics

extension TabItemView {
    func workspaceDropTargetHeight(
        snapshot: SidebarWorkspaceSnapshotBuilder.Snapshot,
        effectiveSubtitle: String?
    ) -> CGFloat? {
        SidebarWorkspaceRowDropMetrics.dropTargetHeight(
            snapshot: snapshot,
            settings: settings,
            effectiveSubtitle: effectiveSubtitle,
            metadataEntryIsExpanded: metadataRowsExpanded,
            metadataBlocksAreExpanded: metadataBlocksExpanded
        )
    }
}
