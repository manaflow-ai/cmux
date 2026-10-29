import CmuxNextControl
import CmuxNextDaemon
import Foundation

/// Builds the control snapshot's Search Tabs facts from the App's owners:
/// recency from the location trail, closing tabs from the strips' visible
/// state, closed tabs from the closed-items log, agent chats' names from
/// the strip's title rule. Main actor; reads only.
enum TabSearchFactsBuilder {
    /// With `cache` the closed tabs are kept between publishes and rebuilt only when a read of
    /// theirs changed (about 10% of main while idle on cmux8s when rebuilt per publish). The
    /// trail and closing tabs stay fresh: the trail is no Observation source, and both are small.
    static func facts(_ services: AppServices, cache: ControlWorkspaceInfoCache? = nil) -> ControlTabSearchFacts {
        ControlTabSearchFacts(lastActive: lastActive(services), closing: closing(services),
                              closed: cache?.closedTabs { closed(services) } ?? closed(services),
                              titles: titles(services.machines.allWorkspaces.map(\.0), TabTitleResolver(services: services)))
    }

    /// The strip's names (`TabTitleResolver`) of the agent chats in `workspaces`, by tab id: their
    /// records are titled with the `about:blank` of the page that draws them. Only agent tabs are
    /// resolved, so a publish stays one walk of the tabs.
    static func titles(_ workspaces: [WorkspaceModel], _ resolver: TabTitleResolver) -> [String: String] {
        var resolver = resolver
        var result: [String: String] = [:]
        for workspace in workspaces {
            resolver.workspaceName = AgentChatTabTitle.workspaceName(workspace)
            for screen in workspace.screens {
                for pane in screen.panes {
                    for tab in pane.tabs where tab.agentSession != nil {
                        result[tab.id] = resolver.title(tab)
                    }
                }
            }
        }
        return result
    }

    /// When the user last settled on each tab (the location trail), by tab id.
    static func lastActive(_ services: AppServices) -> [String: Date] {
        var result: [String: Date] = [:]
        for entry in services.locationTrail.trail.entries {
            let tab = entry.location.key.tab
            if let seen = result[tab], seen >= entry.enteredAt { continue }
            result[tab] = entry.enteredAt
        }
        return result
    }

    /// Tabs whose close is in flight: the daemons' pending close intents (`DaemonStore.closingTabIDs`).
    static func closing(_ services: AppServices) -> Set<String> {
        services.machines.daemons.reduce(into: Set<String>()) { $0.formUnion($1.store.closingTabIDs) }
    }

    /// The closed tabs the daemons record (the only closed history), newest
    /// first. Ids are history ids (`daemon:<closed id>`), so Reopen and Forget
    /// take them as they are.
    private static func closed(_ services: AppServices) -> [ControlClosedTab] {
        // Read inside the publisher's tracking: a close republishes.
        _ = services.closedTabs?.changes.revision
        return listed(DaemonClosedHistory.entries([.tab], in: services)) { ($0.item, $0.daemon.machineID) }.map { entry in
            let item = entry.item, tab = HistoryService.shownTab(item), daemon = entry.daemon
            let workspaceTitle = item.workspaceID.flatMap { daemon.store.workspace(resourceID: $0)?.displayName }
            let local = daemon.machineID == MachineRegistry.localID
            // One close gesture of several tabs is one item: its row reopens all of them.
            let title = item.tabs.count > 1 ? MiscHandlerStrings.tabsClosed(item.tabs.count)
                : HistoryService.realText(item.name) ?? HistoryService.realText(tab?.name)
                    ?? HistoryService.realText(tab?.url) ?? tab?.cwd ?? ""
            return ControlClosedTab(
                id: DaemonClosedHistory.historyID(item.id), kind: tab?.kind == "browser" ? "browser" : "terminal",
                title: title, url: HistoryService.realText(tab?.url), cwd: tab?.cwd,
                workspaceTitle: workspaceTitle,
                machine: local ? nil : services.machines.machineName(daemon.machineID) ?? daemon.machineID,
                closedAt: Date(timeIntervalSince1970: Double(item.closedAtMs) / 1000), isAvailable: daemon.connection != nil)
        }
    }

    /// The closed tab items Search Tabs lists, of `closed` (newest first, each as its item and
    /// machine), as Recently Closed lists them: untouched New Tab pages left out
    /// (HistoryService.isWorthReopening), a page closed again once, at its newest close
    /// (``DaemonClosedHistory/newestOnce(_:_:)``).
    static func listed<T>(_ closed: [T], _ item: (T) -> (item: ClosedItem, machine: String)) -> [T] {
        DaemonClosedHistory.newestOnce(closed.filter { HistoryService.isWorthReopening(item($0).item) }, item)
    }

    /// The closed items Forget deletes for the row of `target`, among `closed`: for a page every
    /// close of it, so no older one takes its row (``DaemonClosedHistory/closes(of:among:_:)``).
    static func forgotten<T>(_ target: T, among closed: [T], _ item: (T) -> (item: ClosedItem, machine: String)) -> [T] {
        DaemonClosedHistory.closes(of: target, among: closed, item)
    }
}
