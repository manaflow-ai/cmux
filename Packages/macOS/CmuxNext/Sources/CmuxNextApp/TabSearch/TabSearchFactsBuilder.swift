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

    private static func closed(_ services: AppServices) -> [ControlClosedTab] {
        guard let tracker = services.closedTabs else { return [] }
        // Read inside the publisher's tracking: a close republishes.
        _ = tracker.changes.revision
        let connected = Set(services.machines.daemons.map(\.machineID))
        return tracker.records.map { record in
            let machineID = ClosedTabTracker.split(record.tabID)?.machine ?? MachineRegistry.localID
            let workspace = ClosedTabTracker.split(record.workspaceID).flatMap { split in
                services.machines.daemon(machine: split.machine)?.store.workspaces.first { $0.id == split.id }
            }
            return ControlClosedTab(
                id: record.tabID, kind: record.kind == .browser ? "browser" : "terminal",
                title: record.title ?? record.url ?? record.cwd ?? "", url: record.url, cwd: record.cwd,
                workspaceTitle: workspace?.displayName,
                machine: machineID == MachineRegistry.localID ? nil : services.machines.machineName(machineID) ?? machineID,
                closedAt: record.closedAt ?? .distantPast, isAvailable: connected.contains(machineID))
        }
    }
}
