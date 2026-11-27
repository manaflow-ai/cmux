@testable import CmuxNextApp
import CmuxNextDaemon

/// What each window shows, for an app test's timeout message: its top page,
/// and whether its workspace content is shown or parked under that page (a
/// tab opened behind a top page lands in the parked content). PinnedPageTests
/// and PasswordManagerRouteTests time out now and then on the fleet; this
/// says whether a top page was in the way.
@MainActor
enum WindowStateReport {
    static func describe(_ services: AppServices, page: InternalPageID? = nil, surface: SurfaceID? = nil) -> String {
        let windows = services.windows.controllers.enumerated().map { index, controller in
            var parts = [
                "window \(index)",
                "top page \(controller.shownTopPage.map { String(describing: $0) } ?? "none")",
                "state page \(controller.state.page.map { String(describing: $0) } ?? "none")",
                "content \(controller.content == nil ? "parked" : "shown")",
                "parked \(controller.parked.count)",
            ]
            let shown = controller.content?.panes.values.map { $0 } ?? []
            let any = controller.workspaceContent?.panes.values.map { $0 } ?? []
            if let page {
                @MainActor func lists(_ panes: [PaneController]) -> Bool {
                    services.pages.tab(of: page, inPanes: panes.map { $0.paneKey }) != nil
                        || panes.contains { $0.pane.tabs.contains { $0.page == page.rawValue } }
                }
                parts.append("\(page.rawValue) in shown content \(lists(shown)), in shown or parked \(lists(any))")
            }
            if let surface {
                let strip = any.first { $0.pane.tabs.contains { $0.surface == surface } }
                parts.append("tab in a strip \(strip != nil), strip shown \(strip.map { pane in shown.contains { $0 === pane } } ?? false)")
            }
            return parts.joined(separator: ", ")
        }
        var lines = windows.isEmpty ? ["no window"] : windows
        if let surface {
            let tab = services.daemon.store.tab(surface: surface)
            let located = tab.flatMap { services.locateTab($0.id) }
            lines.append("store tab pinned \(tab?.pinned.description ?? "gone"), url \(tab?.url ?? "none"), "
                + "pinned url \(tab?.pinnedURL ?? "none"), pane controller \(located.flatMap { services.paneController(for: $0.1) } != nil)")
        }
        return lines.joined(separator: "; ")
    }
}
