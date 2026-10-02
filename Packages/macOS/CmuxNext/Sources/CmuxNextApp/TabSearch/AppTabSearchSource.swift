import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextPalette
import Foundation

/// Search Tabs over the App's mirror (plans/cmux-next/tab-search.md): every
/// open tab on every connected machine, in every window, workspace, screen
/// and pane; recency from the location trail; closed tabs from the
/// closed-items log. Reads only; every change goes through the owner's
/// existing path (Close Tab, Reopen, the closed-items log).
final class AppTabSearchSource: TabSearchSource {
    private unowned let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func tabSearchEntries() -> [TabSearchEntry] {
        openEntries() + closedEntries()
    }

    func focusTab(id: String) {
        guard services.revealTab(id) else { return services.registry.refuse(TabSearchAppStrings.tabGone) }
    }

    func closeTab(id: String) {
        guard services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: id))) else {
            return services.registry.refuse(TabSearchAppStrings.tabGone)
        }
    }

    func reopenClosedTab(id: String) {
        HistoryRestorer(services: services).reopen(closedID: id)
    }

    func forgetClosedTab(id: String) {
        _ = services.closedTabs?.take(id)
    }

    // MARK: Entries

    private func openEntries() -> [TabSearchEntry] {
        let current = services.windows.active?.focusedPane?.selectedTab?.id
        let lastActive = lastActiveByTab()
        let windows = services.windows.registry.value.openWindows
        var windowIndex: [String: Int] = [:]
        var workspaceRank: [String: Int] = [:]
        for (index, window) in windows.enumerated() {
            for (position, workspace) in window.workspaceIDs.enumerated() where workspaceRank[workspace] == nil {
                windowIndex[workspace] = index
                workspaceRank[workspace] = index * 10_000 + position
            }
        }
        let workspaces = services.machines.allWorkspaces.enumerated().sorted { lhs, rhs in
            let l = workspaceRank[lhs.element.0.id] ?? (Int.max / 2 + lhs.offset)
            let r = workspaceRank[rhs.element.0.id] ?? (Int.max / 2 + rhs.offset)
            return l < r
        }
        var entries: [TabSearchEntry] = []
        for (_, (workspace, daemon)) in workspaces {
            let machine = daemon.machineID == MachineRegistry.localID ? nil
                : services.machines.machineName(daemon.machineID) ?? daemon.machineID
            let window = windows.count > 1 ? windowIndex[workspace.id].map { TabSearchAppStrings.window($0 + 1) } : nil
            for screen in workspace.screens {
                for pane in screen.panes {
                    // The strip's visible state: a tab whose close is in
                    // flight is already gone from its pane.
                    let closing = services.paneController(for: pane)?.pendingClosed ?? []
                    for tab in pane.tabs where !closing.contains(tab.id) {
                        entries.append(TabSearchEntry(
                            id: tab.id, kind: kind(tab.kind), title: tab.displayTitle, url: tab.url, cwd: tab.cwd,
                            process: tab.agent?.agent, workspaceID: workspace.id, workspaceTitle: workspace.displayName,
                            windowTitle: window, machine: machine, order: entries.count,
                            state: .open(isCurrent: tab.id == current, lastActive: lastActive[tab.id])))
                    }
                }
            }
        }
        return entries
    }

    private func closedEntries() -> [TabSearchEntry] {
        guard let closed = services.closedTabs else { return [] }
        let connected = Set(services.machines.daemons.map(\.machineID))
        return closed.records.enumerated().map { index, record in
            let split = ClosedTabTracker.split(record.tabID)
            let machineID = split?.machine ?? MachineRegistry.localID
            let workspace = ClosedTabTracker.split(record.workspaceID).flatMap { services.workspace(id: $0.id) }
            return TabSearchEntry(
                id: record.tabID, kind: record.kind == .browser ? .browser : .terminal,
                title: record.title ?? record.url ?? record.cwd ?? "", url: record.url, cwd: record.cwd,
                workspaceTitle: workspace?.displayName,
                machine: machineID == MachineRegistry.localID ? nil : services.machines.machineName(machineID) ?? machineID,
                order: index, state: .closed(closedAt: record.closedAt ?? .distantPast), isAvailable: connected.contains(machineID))
        }
    }

    /// When the user last settled on each tab (the location trail).
    private func lastActiveByTab() -> [String: Date] {
        var result: [String: Date] = [:]
        for entry in services.locationTrail.trail.entries {
            let tab = entry.location.key.tab
            if let seen = result[tab], seen >= entry.enteredAt { continue }
            result[tab] = entry.enteredAt
        }
        return result
    }

    private func kind(_ kind: TabKind) -> TabSearchEntry.Kind {
        switch kind {
        case .pty: .terminal
        case .browser: .browser
        case .remoteTerminal: .remoteTerminal
        case .conversation, .other: .other
        }
    }
}
