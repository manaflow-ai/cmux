import Foundation

extension LaunchSnapshot {
    /// The tab keys (tab resource ids, as `TabModel` keys its tabs) of the tabs the restored windows
    /// show first: each window record front to back (`order`), its workspace's selected screen, and
    /// each pane's selected tab there. Without window records, the active workspace's. The launch
    /// decodes these panes' last frames before any other (`SavedFrameDirectory.prioritize`), so the
    /// first window's pane builds find their frames decoded (#17587).
    public var shownTabKeys: [String] {
        var keys: [String] = []
        let records = (windows?.windows ?? []).sorted { $0.order < $1.order }
        for record in records {
            guard let key = record.workspaceKey, let workspace = tree.workspaces.first(where: { $0.key == key }) else { continue }
            keys += Self.shownTabKeys(workspace, screen: record.screenID, selected: record.selectedTabs)
        }
        if keys.isEmpty, let active = tree.workspaces.first(where: \.active) {
            keys = Self.shownTabKeys(active, screen: nil, selected: [:])
        }
        return keys
    }

    /// The selected tab of each pane on `workspace`'s shown screen (`screen`, else its active one).
    private static func shownTabKeys(_ workspace: WorkspaceSnapshot, screen: ResourceID?,
                                     selected: [String: String]) -> [String] {
        let shown = workspace.screens.first { screen != nil && $0.resourceID == screen }
            ?? workspace.screens.first(where: \.active) ?? workspace.screens.first
        return (shown?.panes ?? []).compactMap { pane -> String? in
            let chosen = pane.resourceID.flatMap { selected[$0.rawValue] }
            let tab = chosen.flatMap { id in pane.tabs.first { $0.tabResourceID?.rawValue == id } }
                ?? (pane.tabs.indices.contains(pane.activeTab) ? pane.tabs[pane.activeTab] : pane.tabs.first)
            return tab?.tabResourceID?.rawValue
        }
    }
}
