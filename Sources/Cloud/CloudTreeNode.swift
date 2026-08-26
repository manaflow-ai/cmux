import Foundation

/// One row of the Cloud outline: a machine, a group header, a cmux-tui workspace,
/// a terminal, the machine's desktop, a forwarded port, or a placeholder line.
///
/// Reference type so `NSOutlineView` can use the node as its item; identity is
/// the stable `id` (machine id, workspace id, terminal id, …), which lets
/// expansion and selection survive a rebuild. Rows below the outline receive
/// only the node's values plus a closure bundle (snapshot-boundary rule).
final class CloudTreeNode: NSObject {
    enum Kind: Equatable {
        case machine(MachineSnapshot)
        /// "Workspaces" group under a machine.
        case workspacesGroup(machineID: String)
        case workspace(machineID: String, CloudTreeWorkspace)
        case terminal(machineID: String, CloudTreeTerminal)
        case desktop(machineID: String)
        /// "Ports" group under a machine.
        case portsGroup(machineID: String)
        case port(machineID: String, CloudTreePort)
        /// A single explanatory line (asleep, connecting, link error, empty).
        case placeholder(machineID: String, CloudTreePlaceholder)
    }

    let id: String
    let kind: Kind
    private(set) var children: [CloudTreeNode]

    init(id: String, kind: Kind, children: [CloudTreeNode] = []) {
        self.id = id
        self.kind = kind
        self.children = children
    }

    var isExpandable: Bool { !children.isEmpty }

    var machineID: String {
        switch kind {
        case .machine(let machine): return machine.id
        case .workspacesGroup(let machineID), .desktop(let machineID), .portsGroup(let machineID):
            return machineID
        case .workspace(let machineID, _), .terminal(let machineID, _), .port(let machineID, _),
             .placeholder(let machineID, _):
            return machineID
        }
    }

    /// The text a quick-search (`/`) matches against.
    var searchableTitle: String {
        switch kind {
        case .machine(let machine): return machine.displayName
        case .workspacesGroup: return String(localized: "cloudTree.group.workspaces", defaultValue: "Workspaces")
        case .workspace(_, let workspace): return workspace.name
        case .terminal(_, let terminal): return terminal.title
        case .desktop: return String(localized: "cloudTree.node.desktop", defaultValue: "Desktop")
        case .portsGroup: return String(localized: "cloudTree.group.ports", defaultValue: "Ports")
        case .port(_, let port): return port.label.map { "\(port.port) \($0)" } ?? String(port.port)
        case .placeholder(_, let placeholder): return placeholder.text
        }
    }

    /// What dragging this row into the main view opens; nil for rows that only organize.
    var dragItem: CloudTreeDragItem? {
        switch kind {
        case .terminal(let machineID, let terminal):
            return .terminal(machineID: machineID, terminalID: terminal.id, title: terminal.title)
        case .desktop(let machineID):
            return .desktop(machineID: machineID)
        case .port(let machineID, let port):
            return .port(machineID: machineID, port: port.port)
        case .machine, .workspacesGroup, .workspace, .portsGroup, .placeholder:
            return nil
        }
    }

    // NSOutlineView keys items by object identity; equality by id keeps
    // `item(atRow:)` lookups stable across snapshot rebuilds.
    override func isEqual(_ object: Any?) -> Bool {
        (object as? CloudTreeNode)?.id == id
    }

    override var hash: Int { id.hashValue }
}

/// A one-line explanatory row under a machine.
struct CloudTreePlaceholder: Equatable {
    enum Style: Equatable {
        case dimmed
        case connecting
        case error
    }

    let text: String
    let style: Style
}

/// Pure assembly of outline nodes from the panel's machine snapshots and the
/// service's tree snapshot. Order: machine → Workspaces (workspace → terminals)
/// → Desktop → Ports; sleeping machines get a single dimmed child.
enum CloudTreeNodeBuilder {
    static func nodes(machines: [MachineSnapshot], tree: CloudTreeSnapshot?) -> [CloudTreeNode] {
        let treeByID = Dictionary((tree?.machines ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return machines.map { machine in
            CloudTreeNode(
                id: nodeID(machine: machine.id),
                kind: .machine(machine),
                children: children(for: machine, tree: treeByID[machine.id])
            )
        }
    }

    static func nodeID(machine: String) -> String { "machine:\(machine)" }
    static func nodeID(workspacesGroup machine: String) -> String { "machine:\(machine)/workspaces" }
    static func nodeID(workspace: String, machine: String) -> String { "machine:\(machine)/ws/\(workspace)" }
    static func nodeID(terminal: String, machine: String) -> String { "machine:\(machine)/term/\(terminal)" }
    static func nodeID(desktop machine: String) -> String { "machine:\(machine)/desktop" }
    static func nodeID(portsGroup machine: String) -> String { "machine:\(machine)/ports" }
    static func nodeID(port: Int, machine: String) -> String { "machine:\(machine)/port/\(port)" }
    static func nodeID(placeholder machine: String) -> String { "machine:\(machine)/placeholder" }

    private static func children(for machine: MachineSnapshot, tree: CloudTreeMachine?) -> [CloudTreeNode] {
        // No service snapshot for this machine yet: nothing to expand.
        guard let tree else { return [] }
        let machineID = machine.id
        var children: [CloudTreeNode] = []

        switch tree.linkState {
        case .asleep:
            children.append(placeholder(
                machineID,
                text: String(localized: "cloudTree.placeholder.asleep", defaultValue: "Asleep \u{2014} open to wake"),
                style: .dimmed
            ))
        case .connecting:
            children.append(placeholder(
                machineID,
                text: String(localized: "cloudTree.placeholder.connecting", defaultValue: "Connecting\u{2026}"),
                style: .connecting
            ))
        case .error:
            children.append(placeholder(
                machineID,
                text: tree.linkError ?? String(localized: "cloudTree.placeholder.linkError", defaultValue: "Link failed"),
                style: .error
            ))
        case .unavailable:
            children.append(placeholder(
                machineID,
                text: String(localized: "cloudTree.placeholder.unavailable", defaultValue: "Sessions unavailable on this machine"),
                style: .dimmed
            ))
        case .connected:
            let workspaces = tree.workspaces.map { workspace in
                CloudTreeNode(
                    id: nodeID(workspace: workspace.id, machine: machineID),
                    kind: .workspace(machineID: machineID, workspace),
                    children: workspace.terminals.map { terminal in
                        CloudTreeNode(
                            id: nodeID(terminal: terminal.id, machine: machineID),
                            kind: .terminal(machineID: machineID, terminal)
                        )
                    }
                )
            }
            if workspaces.isEmpty {
                children.append(placeholder(
                    machineID,
                    text: String(localized: "cloudTree.placeholder.noWorkspaces", defaultValue: "No workspaces yet"),
                    style: .dimmed
                ))
            } else {
                children.append(CloudTreeNode(
                    id: nodeID(workspacesGroup: machineID),
                    kind: .workspacesGroup(machineID: machineID),
                    children: workspaces
                ))
            }
        }

        if tree.desktop {
            children.append(CloudTreeNode(id: nodeID(desktop: machineID), kind: .desktop(machineID: machineID)))
        }
        if !tree.ports.isEmpty {
            children.append(CloudTreeNode(
                id: nodeID(portsGroup: machineID),
                kind: .portsGroup(machineID: machineID),
                children: tree.ports.map { port in
                    CloudTreeNode(id: nodeID(port: port.port, machine: machineID), kind: .port(machineID: machineID, port))
                }
            ))
        }
        return children
    }

    private static func placeholder(_ machineID: String, text: String, style: CloudTreePlaceholder.Style) -> CloudTreeNode {
        CloudTreeNode(
            id: nodeID(placeholder: machineID),
            kind: .placeholder(machineID: machineID, CloudTreePlaceholder(text: text, style: style))
        )
    }

    /// Depth-first flattening in display order (every node expanded); used by
    /// tests and by quick-search.
    static func flattened(_ nodes: [CloudTreeNode]) -> [CloudTreeNode] {
        nodes.flatMap { [$0] + flattened($0.children) }
    }
}
