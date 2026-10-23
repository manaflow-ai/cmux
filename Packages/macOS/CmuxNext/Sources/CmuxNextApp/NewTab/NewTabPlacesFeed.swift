import AppKit
import CmuxNextAgentPane
import CmuxNextCompat
import Foundation

/// Keeps every open New Tab page's open tabs and workspaces current (Leo 2026-10-11: after rapid
/// creates the bar kept "about:blank workspace-7/8" rows for workspaces gone since). A page's
/// places were read once, when it opened or a spare was adopted; now a tab or workspace that
/// comes, goes or is renamed reaches each page still showing as a New Tab page
/// (``AgentPaneView/refreshNewTabPlaces(tabs:workspaces:)``), as seen from its own window. A
/// refresh lists every place, the tab the page was opened beside included.
///
/// Cheap while idle: with no New Tab page open it observes only the pages' ids. With one open, a
/// change compares a plain key (ids, titles, addresses, folders), and the rows, favicons
/// included, are built only when that key changed.
@MainActor
enum NewTabPlacesFeed {
    static func wire(_ tabs: AgentTabStore, services: AppServices) {
        Task { [weak tabs, weak services] in
            var last: [String] = []
            let keys = ObservationStream { [weak tabs, weak services] in
                guard let tabs, let services, !tabs.pageTabs.ids.isEmpty else { return [String]() }
                return key(services)
            }
            for await key in keys where key != last {
                guard let tabs, let services else { return }
                // The first page to open read its places itself.
                let opened = last.isEmpty
                last = key
                if key.isEmpty || opened { continue }
                push(tabs, services: services)
            }
        }
    }

    /// Everything the bar's rows are made of, as plain text: a change here is a change of rows.
    private static func key(_ services: AppServices) -> [String] {
        services.machines.allWorkspaces.flatMap { workspace, _ in
            ["\(workspace.id)\t\(workspace.displayName)"] + workspace.screens.flatMap(\.panes).flatMap(\.tabs).map { tab in
                [tab.id, "\(tab.kind)", tab.displayTitle, tab.url ?? "", tab.cwd ?? "", tab.agentSession?.session ?? ""]
                    .joined(separator: "\t")
            }
        }
    }

    /// The places are built once per window shown workspace, not once per open page: a create
    /// with N pages open built every place N times (each a walk of every tab of every workspace,
    /// with its icons), in the frames right after the key. A page lists every place but itself,
    /// and a New Tab page is no place (``NewTabPage/place(_:home:)``), so the pages of one window
    /// share one list; a page that is a place (its chat started) gets its own.
    private static func push(_ tabs: AgentTabStore, services: AppServices) {
        var pages: [(key: String, current: String?, view: AgentPaneView)] = []
        for key in tabs.newTabPages.keys {
            guard let view = tabs.views[key] else { continue }
            let window = view.window.flatMap { services.windows.owner(of: $0) } ?? services.windows.active
            pages.append((key, window?.state.workspaceID, view))
        }
        let places = sharedPlaces(for: pages.map { ($0.key, $0.current) },
                                  build: { NewTabPage.places(services, excluding: $0, current: $1) },
                                  lists: { all, key in all.tabs.contains { $0.id == key } })
        for page in pages {
            guard let mine = places[page.key] else { continue }
            page.view.refreshNewTabPlaces(tabs: mine.tabs, workspaces: mine.workspaces)
        }
    }

    /// Each page's places, built once per shown workspace (`current`) and again only for a page
    /// that `lists` itself as a place, which gets the list without itself.
    /// - Parameters:
    ///   - pages: Each open New Tab page's key and its window's shown workspace.
    ///   - build: The places of `current`, without the page `excluding` (nil: every place).
    ///   - lists: Whether the places list the page `key`.
    /// - Returns: The places each page shows, by page key.
    static func sharedPlaces<Places>(for pages: [(key: String, current: String?)],
                                     build: (_ excluding: String?, _ current: String?) -> Places,
                                     lists: (Places, _ key: String) -> Bool) -> [String: Places] {
        var shared: [String?: Places] = [:]
        var result: [String: Places] = [:]
        for page in pages {
            let all = shared[page.current] ?? build(nil, page.current)
            shared[page.current] = all
            result[page.key] = lists(all, page.key) ? build(page.key, page.current) : all
        }
        return result
    }
}
