import CmuxNextControl
import CmuxNextPalette
import Foundation

/// Search Tabs entries from a control snapshot: one pure mapping shared by
/// the palette page (from a topology built now) and `tabs.search` (from the
/// published snapshot, off the main actor).
nonisolated enum TabSearchEntries {
    static func entries(_ topology: ControlTopology, _ facts: ControlTabSearchFacts) -> [TabSearchEntry] {
        open(topology, facts) + closed(facts)
    }

    private static func open(_ topology: ControlTopology, _ facts: ControlTabSearchFacts) -> [TabSearchEntry] {
        // Layout order: windows in order, each window's workspaces in order,
        // then workspaces no window lists.
        var rank: [String: Int] = [:]
        var windowNumber: [String: Int] = [:]
        for (index, window) in topology.windows.enumerated() {
            for (position, workspace) in window.workspaceIDs.enumerated() where rank[workspace] == nil {
                rank[workspace] = index * 10_000 + position
                windowNumber[workspace] = index + 1
            }
        }
        let workspaces = topology.workspaces.enumerated().sorted { lhs, rhs in
            (rank[lhs.element.id] ?? Int.max / 2 + lhs.offset) < (rank[rhs.element.id] ?? Int.max / 2 + rhs.offset)
        }.map(\.element)
        let machineNames = Dictionary(topology.sessions.map { ($0.id, $0.machineName ?? $0.machineID) }, uniquingKeysWith: { first, _ in first })
        let current = topology.focus.tabID
        var entries: [TabSearchEntry] = []
        for workspace in workspaces {
            let machine = workspace.sessionID.flatMap { machineNames[$0] }
            let window = topology.windows.count > 1 ? windowNumber[workspace.id].map(TabSearchAppStrings.window) : nil
            for tab in workspace.panes.flatMap(\.tabs) where !facts.closing.contains(tab.id) {
                entries.append(TabSearchEntry(
                    id: tab.id, kind: kind(tab.kind), title: tab.title, url: tab.url, cwd: tab.cwd, process: tab.agent,
                    workspaceID: workspace.id, workspaceTitle: workspace.name, windowTitle: window, machine: machine,
                    order: entries.count, state: .open(isCurrent: tab.id == current, lastActive: facts.lastActive[tab.id])))
            }
        }
        return entries
    }

    private static func closed(_ facts: ControlTabSearchFacts) -> [TabSearchEntry] {
        facts.closed.enumerated().map { index, record in
            TabSearchEntry(id: record.id, kind: record.kind == "browser" ? .browser : .terminal, title: record.title, url: record.url,
                           cwd: record.cwd, workspaceTitle: record.workspaceTitle, machine: record.machine, order: index,
                           state: .closed(closedAt: record.closedAt), isAvailable: record.isAvailable)
        }
    }

    private static func kind(_ kind: String) -> TabSearchEntry.Kind {
        switch kind {
        case "terminal": .terminal
        case "browser": .browser
        case "remote-terminal": .remoteTerminal
        default: .other
        }
    }
}
