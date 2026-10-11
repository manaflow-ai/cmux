import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextHistory
import Foundation

/// The New Tab page's Recently Closed section (cx-d0d.60): the newest closed
/// tabs, screens and workspaces from History (`HistoryService.closedEntries`),
/// pushed to every page as they change. A row reopens through History's own
/// path (`HistoryRestorer.reopen`), as History > Recently Closed does.
@MainActor
enum NewTabClosed {
    /// Keeps every page of `tabs` showing the newest closed items. Favicons
    /// are looked up outside the observed read and encoded once per URL, so
    /// a favicon landing elsewhere re-runs nothing.
    static func wire(_ tabs: AgentTabStore, services: AppServices) {
        Task { [weak tabs, weak services] in
            var icons: [String: String] = [:]
            var last: [AgentPaneClosedItem]?
            for await listed in ObservationStream({ [weak services] in services.map(items) ?? [] }) where listed != last {
                guard let tabs, let services else { return }
                last = listed
                let shown = listed.map { item in
                    guard item.kind == .browser, let address = item.detail else { return item }
                    if icons[address] == nil, let url = URL(string: address) {
                        icons[address] = AppServices.dataURL(services.siteFavicon(url, profile: .default))
                    }
                    var item = item
                    item.icon = icons[address]
                    return item
                }
                tabs.pageChats.closed = shown
                for view in Array(tabs.views.values) + tabs.standaloneViews.allObjects { view.recentlyClosed = shown }
            }
        }
    }

    /// Reopens the closed item with history id `id`; one gone since the page drew refuses.
    static func reopen(_ id: String, services: AppServices) {
        guard let entry = services.history.closedEntries().first(where: { $0.id == id }), case .closed(let item) = entry.payload else {
            return services.registry.refuse(HistoryAppStrings.entryGone)
        }
        HistoryRestorer(services: services).reopen(item)
    }

    /// The newest closed items, as the page draws them, without favicons.
    /// Reads the closed-tab tracker's revision, the one part of History's
    /// closed list that is not observable state itself. Leaves out tabs
    /// closed in incognito windows, and the app's own record of a workspace
    /// whose daemon keeps closed history (the daemon's entry stands).
    static func items(_ services: AppServices) -> [AgentPaneClosedItem] {
        _ = services.closedTabs?.changes.revision
        return services.history.closedEntries().sorted { $0.time > $1.time }.lazy.compactMap { entry -> AgentPaneClosedItem? in
            guard case .closed(let item) = entry.payload, !(services.closedTabs?.isIncognito(item.id) ?? false) else { return nil }
            if entry.id.hasPrefix("closed:workspace:"),
               services.machines.daemons.first(where: { $0.machineID == item.machine })?.store.servesStateResources == true { return nil }
            let kind: AgentPaneClosedItem.Kind = switch item.kind {
            case .terminalTab: .terminal
            case .browserTab: .browser
            case .screen: .screen
            case .workspace: .workspace
            }
            let detail = item.url ?? item.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? entry.detail
            return AgentPaneClosedItem(id: entry.id, kind: kind, title: title(entry.title, item.url, item.cwd), detail: detail, closedAt: entry.time,
                                       icon: nil, isAvailable: entry.isAvailable)
        }.prefix(AgentPaneClosedItem.maximumPushed).map(\.self)
    }

    /// A title that is only the address or folder (a daemon record keeps no page title) reads
    /// as host and path, or the folder's name, so the row does not repeat its detail.
    static func title(_ title: String, _ url: String?, _ cwd: String?) -> String {
        if title == url, let url = url.flatMap(URL.init(string:)), let host = url.host() {
            return host + (url.path() == "/" ? "" : url.path())
        }
        if title == cwd, let cwd { return (cwd as NSString).lastPathComponent }
        return title
    }
}
