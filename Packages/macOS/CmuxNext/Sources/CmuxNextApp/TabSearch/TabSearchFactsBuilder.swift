import CmuxNextControl
import Foundation

/// Builds the control snapshot's Search Tabs facts from the App's owners:
/// recency from the location trail, closing tabs from the strips' visible
/// state, closed tabs from the closed-items log. Main actor; reads only.
enum TabSearchFactsBuilder {
    static func facts(_ services: AppServices) -> ControlTabSearchFacts {
        ControlTabSearchFacts(lastActive: lastActive(services), closing: closing(services), closed: closed(services))
    }

    private static func lastActive(_ services: AppServices) -> [String: Date] {
        var result: [String: Date] = [:]
        for entry in services.locationTrail.trail.entries {
            let tab = entry.location.key.tab
            if let seen = result[tab], seen >= entry.enteredAt { continue }
            result[tab] = entry.enteredAt
        }
        return result
    }

    private static func closing(_ services: AppServices) -> Set<String> {
        var result = Set<String>()
        for (workspace, _) in services.machines.allWorkspaces {
            for pane in workspace.screens.flatMap(\.panes) {
                if let pending = services.paneController(for: pane)?.pendingClosed { result.formUnion(pending) }
            }
        }
        return result
    }

    /// The closed tabs the daemons record (the only closed history), newest
    /// first. Ids are history ids (`daemon:<closed id>`), so Reopen and Forget
    /// take them as they are.
    private static func closed(_ services: AppServices) -> [ControlClosedTab] {
        // Read inside the publisher's tracking: a close republishes.
        _ = services.closedTabs?.changes.revision
        // Untouched New Tab pages are left out, as in Recently Closed (HistoryService.isWorthReopening).
        return DaemonClosedHistory.entries([.tab], in: services).filter { HistoryService.isWorthReopening($0.item) }.map { entry in
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
}
