extension AppDelegate {
    func performEqualizeSplitsShortcut() {
        if let workspace = tabManager?.selectedWorkspace {
            _ = tabManager?.equalizeSplits(tabId: workspace.id)
        }
    }
}
