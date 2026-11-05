import CmuxNextActions
import CmuxNextDaemon
import CmuxNextTabs
import Foundation

// The tabs a tab group action acts on. Every entrypoint (the tab menu, the palette, a shortcut, the
// CLI, MCP) resolves them here, so a right-click and Cmd-Shift-P on the same tab act on the same tabs.
extension AppActionContext {
    /// The tabs a tab group action acts on, in display order, with their pane: the `tabs` argument
    /// (comma-separated ids, all in one pane) when given, else the targeted or focused tab with the
    /// rest of its strip's selection (``actingTabs(_:_:_:)``). Refuses like ``daemonTab(_:)``.
    func actionTabs(_ invocation: ActionInvocation) -> (tabs: [TabModel], pane: PaneModel)? {
        if let list = invocation["tabs"]?.stringValue {
            var found: [(TabModel, PaneModel)] = []
            for id in list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !id.isEmpty {
                guard let hit = targetTab(id, invocation) ?? notFound(RefusalStrings.noTab(id)) else { return nil }
                found.append(hit)
            }
            guard let pane = found.first?.1 ?? refuse(RefusalStrings.noTab(list)) else { return nil }
            guard found.allSatisfy({ $0.1 === pane }) else { return refuse(RefusalStrings.tabsInDifferentPanes) }
            return (found.map(\.0), pane)
        }
        guard let (tab, pane) = daemonTab(invocation) else { return nil }
        guard let controller = services.paneController(for: pane) else { return ([tab], pane) }
        let tabs = actingTabs(invocation, controller, CmuxNextTabs.TabID(tab.id)).compactMap { controller.tab($0) }
        return (tabs.contains { $0.id == tab.id } ? tabs : [tab], pane)
    }
}
