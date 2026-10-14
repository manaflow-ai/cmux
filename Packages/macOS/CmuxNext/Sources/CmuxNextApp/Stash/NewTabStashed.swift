import CmuxNextAgentPane
import CmuxNextCompat

/// The New Tab page's Stashed link: every page hears how many tabs are stashed (none, or a
/// daemon without stash-v1: no link), again when the count or the set of pages changes. The
/// stashes are read once this Mac's daemon serves them, and again on each stash change it
/// publishes on `session.events` (the CLI, MCP, another window).
@MainActor
enum NewTabStashed {
    static func wire(_ tabs: AgentTabStore, services: AppServices) {
        Task { [weak services] in
            var last: Int?
            let changes = ObservationStream { [weak services] () -> Int? in
                guard let services, services.historyPage.stash.serves(services.daemon) else { return nil }
                return services.daemon.store.session.mirror?.stashChanges ?? 0
            }
            for await change in changes where change != last {
                last = change
                if change != nil { await services?.historyPage.stash.model.reload() }
            }
        }
        Task { [weak tabs, weak services] in
            var last: [String] = []
            let keys = ObservationStream { [weak tabs, weak services] in
                guard let tabs, let services else { return [String]() }
                let count = services.historyPage.stash.serves(services.daemon) ? services.historyPage.stash.model.tabCount : 0
                return [String(count)] + tabs.views.keys.sorted()
            }
            for await key in keys where key != last {
                guard let tabs, let first = key.first else { return }
                last = key
                for view in Array(tabs.views.values) + tabs.standaloneViews.allObjects {
                    AgentPageEvent.pushStashedCount(Int(first) ?? 0, to: view)
                }
            }
        }
    }
}
