import CmuxCloud
import CmuxSurfaceCatalogModel

/// Regroups a Cloud machine's rows for display, after the catalog tree is
/// built: its workspaces sit directly under the machine (followed by New
/// Workspace), then Displays, then one tab row for Ports, Terminals and
/// Resources, then a spacer before the next machine. The Terminals tab lists
/// every terminal on the machine, each with the workspace it is in.
///
/// Display only. The catalog tree keeps its groups, so saved order, pins and
/// the catalog's own reorders are unchanged. The tab row takes the id of the
/// open group, so its rows keep their parent's organization key, and it keeps
/// every group it replaced, so presenting an already presented tree again
/// gives the same result.
struct CloudTreeMachineDetailLayout {
    /// The open tab per machine. Not persisted: a relaunch opens machines
    /// with every tab closed.
    private(set) var selection: [SurfaceMachineID: CloudTreeMachineDetailTab] = [:]

    /// Opens `tab` on `machine`, or closes it when it is already open.
    /// Returns the tab that is open afterwards.
    @discardableResult
    mutating func toggle(_ tab: CloudTreeMachineDetailTab, machine: SurfaceMachineID) -> CloudTreeMachineDetailTab? {
        if selection[machine] == tab {
            selection[machine] = nil
        } else {
            selection[machine] = tab
        }
        return selection[machine]
    }

    func present(_ nodes: [CloudTreeNode]) -> [CloudTreeNode] {
        for node in nodes {
            if case .machine = node.kind {
                node.children = machineChildren(node)
            } else {
                _ = present(node.children)
            }
            if case .cloudMachinesSection = node.kind { closeSection(node) }
        }
        return nodes
    }

    /// The gap after the fleet belongs to the section, not its last machine,
    /// so My Devices keeps the same space whether that machine is open or
    /// collapsed.
    private func closeSection(_ section: CloudTreeNode) {
        let spacerID = "cloud-machines-section/end-spacer"
        let existing = section.children.first { $0.id == spacerID }
        section.children.removeAll { $0.id == spacerID }
        guard let last = section.children.last(where: { if case .machine = $0.kind { return true }; return false }) else { return }
        last.children.removeAll { if case .machineEndSpacer = $0.kind { return true }; return false }
        section.children.append(existing ?? CloudTreeNode(id: spacerID, kind: .machineEndSpacer(machine: .cloud("cloud-machines-section"))))
    }

    private func machineChildren(_ node: CloudTreeNode) -> [CloudTreeNode] {
        let machine = node.machine
        // Rows this layout made on an earlier pass, which the outline may
        // already hold. Reusing them keeps the outline's objects current.
        var made: [String: CloudTreeNode] = [:]
        for child in node.children {
            switch child.kind {
            case .machineDetailTabs, .machineEndSpacer:
                made[child.id] = child
                for row in child.children { made[row.id] = row }
            default: break
            }
        }
        var rows: [CloudTreeNode] = []
        var displays: CloudTreeNode?
        var pools: [CloudTreeMachineDetailTab: CloudTreeNode] = [:]
        func collect(_ child: CloudTreeNode) {
            switch child.kind {
            case .workspacesGroup: rows.append(contentsOf: child.children)
            case .displaysPool: displays = child
            case .portsGroup: pools[.ports] = child
            case .terminalsPool: pools[.terminals] = child
            case .resourcesPool: pools[.resources] = child
            case .machineDetailTabs: child.detailPools.forEach(collect)
            case .machineEndSpacer: break
            default: rows.append(child)
            }
        }
        node.children.forEach(collect)
        if let displays { rows.append(displays) }
        let tabs = CloudTreeMachineDetailTab.allCases.filter { pools[$0] != nil }
        if !tabs.isEmpty {
            let row = tabRow(machine: machine, tabs: tabs, pools: pools)
            row.children = row.children.map { Self.reuse($0, from: made) }
            rows.append(Self.reuse(row, from: made))
        }
        // A machine with nothing under it gets no gap, so it shows no disclosure.
        if !rows.isEmpty {
            rows.append(Self.reuse(CloudTreeNode(id: "\(Self.baseID(machine))/end-spacer", kind: .machineEndSpacer(machine: machine)), from: made))
        }
        return rows
    }

    /// The object this layout made for `node.id` last time, updated to `node`;
    /// otherwise `node` itself.
    private static func reuse(_ node: CloudTreeNode, from made: [String: CloudTreeNode]) -> CloudTreeNode {
        guard let existing = made[node.id], existing !== node, existing.structureTag == node.structureTag else { return node }
        existing.take(from: node)
        return existing
    }

    private func tabRow(
        machine: SurfaceMachineID,
        tabs: [CloudTreeMachineDetailTab],
        pools: [CloudTreeMachineDetailTab: CloudTreeNode]
    ) -> CloudTreeNode {
        let selected = selection[machine].flatMap { tabs.contains($0) ? $0 : nil }
        var counts: [CloudTreeMachineDetailTab: Int] = [:]
        if let ports = pools[.ports] {
            counts[.ports] = ports.children.filter { if case .port = $0.kind { return true }; return false }.count
        }
        if let terminals = pools[.terminals], case .terminalsPool(_, let count) = terminals.kind {
            counts[.terminals] = count
        }
        let payload = CloudTreeMachineDetailTabs(machine: machine, tabs: tabs, counts: counts, selected: selected)
        let open = selected.flatMap { pools[$0] }
        var children = open?.children ?? []
        if selected == .terminals, let terminals = open {
            children = terminalsTabRows(terminals, machine: machine)
        }
        let row = CloudTreeNode(id: open?.id ?? "\(Self.baseID(machine))/details", kind: .machineDetailTabs(payload), children: children)
        row.detailPools = tabs.compactMap { pools[$0] }
        return row
    }

    /// New Terminal, then every terminal on the machine, each labelled with
    /// the workspaces showing it. A machine with no terminals keeps the
    /// pool's own "No terminals yet".
    private func terminalsTabRows(_ terminals: CloudTreeNode, machine: SurfaceMachineID) -> [CloudTreeNode] {
        var rows: [CloudTreeNode] = []
        if machine.cloudMachineID != nil {
            rows.append(CloudTreeNode(id: "\(Self.baseID(machine))/terminals/new-terminal", kind: .createAction(.newTerminal(machine))))
        }
        rows.append(contentsOf: terminals.children.map(Self.labelledWithWorkspace))
        return rows
    }

    /// The same terminal row with its workspace names as its detail.
    private static func labelledWithWorkspace(_ node: CloudTreeNode) -> CloudTreeNode {
        guard case .terminal(var row) = node.kind else { return node }
        var names: [String] = []
        for view in row.resource.remoteViews ?? [] where !names.contains(view.workspace.name) {
            names.append(view.workspace.name)
        }
        row.workspaceLabel = names.isEmpty ? nil : names.joined(separator: ", ")
        return CloudTreeNode(id: node.id, kind: .terminal(row), children: node.children, isPinned: node.isPinned)
    }

    private static func baseID(_ machine: SurfaceMachineID) -> String { "machine:\(machine.rawValue)" }
}
