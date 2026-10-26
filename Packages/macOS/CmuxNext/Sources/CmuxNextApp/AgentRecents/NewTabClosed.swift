import CmuxNextAgentPane
import CmuxNextBridge
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
                // Encoded once here; every page gets the same payload (a251: one encode per page before).
                let list = AgentPaneClosedList(shown)
                tabs.pageChats.closed = list
                for view in Array(tabs.views.values) + tabs.standaloneViews.allObjects { view.recentlyClosed = list }
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

    /// The newest closed items, as the page draws them, without favicons:
    /// the daemons' closed history (the only one). Reads the closed-tab
    /// feed's revision, so a close or a reopen redraws the page.
    static func items(_ services: AppServices) -> [AgentPaneClosedItem] {
        _ = services.closedTabs?.changes.revision
        return services.history.closedEntries().sorted { $0.time > $1.time }.lazy.compactMap { entry -> AgentPaneClosedItem? in
            guard case .closed(let item) = entry.payload else { return nil }
            let kind = Self.kind(for: item)
            let detail = item.url ?? item.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? entry.detail
            let rowTitle = title(entry.title, item.url, item.cwd, manualTitle: item.manualTitle, agentSession: item.agentSession,
                                 machine: item.machine, localHost: services.agentTabs.localHost)
            return AgentPaneClosedItem(id: entry.id, kind: kind, title: rowTitle, detail: detail, closedAt: entry.time,
                                       icon: nil, isAvailable: entry.isAvailable)
        }.prefix(AgentPaneClosedItem.maximumPushed).map(\.self)
    }

    static func kind(for item: CmuxNextHistory.ClosedItem) -> AgentPaneClosedItem.Kind {
        switch item.kind {
        case .terminalTab: .terminal
        case .browserTab where item.agentSession != nil: .agent
        case .browserTab: .browser
        case .screen: .screen
        case .workspace: .workspace
        }
    }

    /// A closed agent keeps an explicit daemon/tab name. Otherwise its local generated title is
    /// read by machine plus session, so a same-named remote session cannot leak into this row;
    /// a missing cache gets the stable agent title. Browser rows retain their existing fallback.
    static func title(_ title: String, _ url: String?, _ cwd: String?, manualTitle: String? = nil,
                      agentSession: CmuxNextHistory.ClosedItem.AgentSession? = nil, machine: String? = nil,
                      localHost: String? = nil, turns: AgentTurnStateStore = .shared) -> String {
        if let manualTitle { return manualTitle }
        if let agentSession {
            if machine == MachineRegistry.localID, let host = localHost, let session = agentSession.sessionID {
                let ref = AgentSessionRef(host: host, session: session, harness: agentSession.harness)
                if let generated = turns.generatedTitle(for: ref), !generated.isEmpty { return generated }
            }
            return AgentPaneModel.tabTitle
        }
        if title == url, let url = url.flatMap(URL.init(string:)), let host = url.host() {
            return host + (url.path() == "/" ? "" : url.path())
        }
        if title == cwd, let cwd { return (cwd as NSString).lastPathComponent }
        return title
    }
}
