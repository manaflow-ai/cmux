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
    /// Keeps every page of `tabs` showing the newest closed items.
    static func wire(_ tabs: AgentTabStore, services: AppServices) {
        Task { [weak tabs, weak services] in
            for await items in ObservationStream({ [weak services] in services.map(items) ?? [] }) {
                guard let tabs else { return }
                tabs.pageChats.closed = items
                for view in Array(tabs.views.values) + tabs.standaloneViews.allObjects { view.recentlyClosed = items }
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

    /// The newest closed items, as the page draws them.
    static func items(_ services: AppServices) -> [AgentPaneClosedItem] {
        services.history.closedEntries().sorted { $0.time > $1.time }.prefix(AgentPaneClosedItem.maximumPushed).compactMap { entry in
            guard case .closed(let item) = entry.payload else { return nil }
            let kind: AgentPaneClosedItem.Kind = switch item.kind {
            case .terminalTab: .terminal
            case .browserTab: .browser
            case .screen: .screen
            case .workspace: .workspace
            }
            let url = item.url.flatMap(URL.init(string:))
            let detail = item.url ?? item.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? entry.detail
            return AgentPaneClosedItem(id: entry.id, kind: kind, title: entry.title, detail: detail, closedAt: entry.time,
                                       icon: url.flatMap { AppServices.dataURL(services.siteFavicon($0, profile: .default)) },
                                       isAvailable: entry.isAvailable)
        }
    }
}
