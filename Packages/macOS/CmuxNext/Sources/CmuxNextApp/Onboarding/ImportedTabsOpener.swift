import CmuxNextBrowserImport
import CmuxNextDaemon

/// Open Tabs: each imported source's last session opens as its own workspace
/// (``ImportSummary/tabWorkspaces``), its pages in the source's order on the
/// profile the import put that source in, pinned tabs pinned.
enum ImportedTabsOpener {
    @MainActor
    static func open(_ summary: ImportSummary, services: AppServices) {
        let daemon = services.activeDaemon
        guard daemon.supports(DaemonCapability.frontendBrowserTabs.rawValue) else { return }
        let browserTabs = services.cache.browserTabs
        // An older daemon without the capability would ignore the field: send it only when served.
        let background: Bool? = daemon.supports(DaemonCapability.frontendBrowserActivate.rawValue) ? false : nil
        for workspace in summary.tabWorkspaces {
            let tabs = workspace.tabs.compactMap { tab -> (ImportedTab, BrowserEngine)? in
                guard case .open(let choice) = browserTabs.resolve(requested: nil, url: tab.url) else { return nil }
                return (tab, choice.engine)
            }
            guard !tabs.isEmpty else { continue }
            // One create with the first tab, then one request per tab sent to the workspace: no terminal hosts them.
            let pages = tabs.map { WorkspaceFirstBrowserTab(url: $0.0.url.absoluteString, engine: $0.1, title: $0.0.title, profileID: workspace.profileID) }
            WorkspaceHandlers.show(.browsers(pages, name: workspace.name, background: background) { connection, index, created in
                if tabs[index].0.pinned { _ = try? await connection.setTabPinned(created.surface, true) }
            }, services: services)
        }
    }
}
