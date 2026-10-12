import CmuxNextAgentPane
import CmuxNextCompat
import Foundation

/// Keeps every open New Tab page's open tabs and workspaces current (Leo 2026-10-11: after rapid
/// creates the bar kept "about:blank workspace-7/8" rows for workspaces gone since). A page's
/// places were read once, when it opened or a spare was adopted; now a tab or workspace that
/// comes or goes reaches each page still showing as a New Tab page
/// (``AgentPaneView/refreshNewTabPlaces(tabs:workspaces:)``).
@MainActor
enum NewTabPlacesFeed {
    private struct Places: Equatable, Sendable {
        var tabs: [AgentPaneOmnibar.Tab]
        var workspaces: [AgentPaneOmnibar.Workspace]
    }

    static func wire(_ tabs: AgentTabStore, services: AppServices) {
        Task { [weak tabs, weak services] in
            var last: Places?
            let places = ObservationStream { [weak services] in
                services.map { NewTabPage.places($0, excluding: nil) }.map { Places(tabs: $0.tabs, workspaces: $0.workspaces) }
                    ?? Places(tabs: [], workspaces: [])
            }
            for await listed in places where listed != last {
                guard let tabs else { return }
                last = listed
                for view in Array(tabs.views.values) + tabs.standaloneViews.allObjects where view.model.newTab != nil {
                    view.refreshNewTabPlaces(tabs: listed.tabs, workspaces: listed.workspaces)
                }
            }
        }
    }
}
