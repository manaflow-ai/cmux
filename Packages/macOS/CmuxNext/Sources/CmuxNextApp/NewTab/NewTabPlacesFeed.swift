import AppKit
import CmuxNextAgentPane
import CmuxNextWakeups
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
/// included, are built only when that key changed. The pages' push is a write to their page
/// models (a hidden page's router holds it), so it is a ``ServiceObservation`` in the visible
/// class: one flush per frame behind the person's input, however many tabs an agent renames.
@MainActor
final class NewTabPlacesFeed {
    private var last: [String] = []
    private var observation: ServiceObservation<[String]>?

    /// Starts the feed of `tabs`' pages; `tabs` keeps it (``AgentTabStore/placesFeed``).
    static func wire(_ tabs: AgentTabStore, services: AppServices) {
        guard tabs.placesFeed == nil else { return }
        let feed = NewTabPlacesFeed()
        tabs.placesFeed = feed
        feed.observation = ServiceObservation(.visible, owner: "NewTab.places", on: services.mainWork) { [weak tabs, weak services] in
            guard let tabs, let services, !tabs.pageTabs.ids.isEmpty else { return [String]() }
            return key(services)
        } apply: { [weak feed, weak tabs, weak services] key in
            guard let feed, let tabs, let services else { return }
            feed.changed(to: key, tabs: tabs, services: services)
        }
    }

    private func changed(to key: [String], tabs: AgentTabStore, services: AppServices) {
        // The first page to open read its places itself.
        let opened = last.isEmpty
        last = key
        if key.isEmpty || opened { return }
        Self.push(tabs, services: services)
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

    private static func push(_ tabs: AgentTabStore, services: AppServices) {
        for key in tabs.newTabPages.keys {
            guard let view = tabs.views[key] else { continue }
            let window = view.window.flatMap { services.windows.owner(of: $0) } ?? services.windows.active
            let places = NewTabPage.places(services, excluding: key, current: window?.state.workspaceID)
            view.refreshNewTabPlaces(tabs: places.tabs, workspaces: places.workspaces)
        }
    }
}
