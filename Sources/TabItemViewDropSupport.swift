import CoreGraphics
import Foundation

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

    func closeWorkspace(method: StaticString) {
        #if DEBUG
        let workspaceDebugID = tab.id.uuidString.prefix(5)
        cmuxDebugLog("sidebar.close workspace=\(workspaceDebugID) method=\(method)")
        #endif
        tabManager.closeWorkspaceWithConfirmation(tab)
    }

    func refreshWorkspaceSnapshotAfterObservation(source: StaticString) {
        logWorkspaceObservationInvalidation(source: source)
        refreshWorkspaceSnapshot()
    }

    func openPendingFinderDirectoryRequest() async {
        guard let request = workspaceFinderDirectoryOpenRequest else { return }
        await WorkspaceFinderDirectoryOpener.openInFinder(request.directoryURL)
        guard !Task.isCancelled, workspaceFinderDirectoryOpenRequest == request else { return }
        workspaceFinderDirectoryOpenRequest = nil
    }

    private func logWorkspaceObservationInvalidation(source: StaticString) {
        #if DEBUG
        let description = tab.customDescription ?? ""
        let workspaceDebugID = tab.id.uuidString.prefix(8)
        let titlePreview = debugSidebarTextPreview(tab.title)
        let descriptionLength = (description as NSString).length
        let descriptionPreview = debugSidebarTextPreview(description)
        cmuxDebugLog(
            "sidebar.row.invalidate workspace=\(workspaceDebugID) " +
            "source=\(source) " +
            "title=\"\(titlePreview)\" " +
            "descLen=\(descriptionLength) " +
            "desc=\"\(descriptionPreview)\""
        )
        #endif
    }

    private func debugSidebarTextPreview(_ text: String, limit: Int = 120) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        if escaped.count <= limit {
            return escaped
        }
        let prefix = escaped.prefix(limit)
        return "\(prefix)..."
    }
}
