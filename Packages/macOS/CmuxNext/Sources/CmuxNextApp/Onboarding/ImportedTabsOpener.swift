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
            WorkspaceHandlers.createAndShow(services: services, name: workspace.name) { connection, terminal in
                guard let pane = terminal.pane else { return }
                for (index, (tab, engine)) in tabs.enumerated() {
                    let created = try await connection.newFrontendBrowserTab(url: tab.url.absoluteString, engine: engine, in: pane, title: tab.title,
                                                                             profileID: workspace.profileID, activate: index == 0 ? nil : background)
                    if tab.pinned { _ = try? await connection.setTabPinned(created.surface, true) }
                }
                if let surface = terminal.surface { try await connection.closeTab(surface) }
            }
        }
    }
}
