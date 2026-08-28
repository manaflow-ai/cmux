import Foundation

/// One row of the Cloud outline, built from the surface catalog: this Mac or a
/// cloud machine, a pool ("Terminals", "Displays"), a group header, a workspace
/// (cmux-tui on a machine, or the local workspace that projects a terminal), a
/// terminal, a VNC display, a browser, a forwarded port, or a placeholder line.
///
/// Reference type so `NSOutlineView` can use the node as its item; identity is
/// the stable `id` (machine id, workspace id, resource id, …), which lets
/// expansion and selection survive a rebuild. Rows below the outline receive
/// only the node's values plus a closure bundle (snapshot-boundary rule).
final class CloudTreeNode: NSObject {
    enum Kind: Equatable {
        /// A cloud machine: the fleet row (plan/free-access state) plus what the catalog knows.
        case machine(MachineSnapshot, SurfaceMachineInfo?)
        /// This Mac.
        case localMachine(CloudTreeLocalMachineRow)
        /// "Terminals" pool under a cloud machine: every terminal the machine owns, one
        /// row per identity, whatever workspaces (zero or more) show it.
        case terminalsPool(machine: SurfaceMachineID, count: Int)
        /// "Displays" pool under a cloud machine: its VNC displays.
        case displaysPool(machine: SurfaceMachineID, count: Int)
        /// "Workspaces" group under a machine.
        case workspacesGroup(machine: SurfaceMachineID)
        /// A cmux-tui workspace on a cloud machine; its children are pointer rows into
        /// the machine's pools.
        case workspace(machine: SurfaceMachineID, SurfaceRemoteWorkspace, terminalCount: Int)
        /// A local workspace, grouping the local terminals it projects.
        case localWorkspace(CloudTreeLocalWorkspaceRow)
        case terminal(CloudTreeTerminalRow)
        /// One VNC display of a machine.
        case display(SurfaceResource)
        /// "Browsers" group (this Mac).
        case browsersGroup(machine: SurfaceMachineID)
        case browser(CloudTreeBrowserRow)
        /// "Ports" group under a cloud machine.
        case portsGroup(machine: SurfaceMachineID)
        case port(SurfaceResource)
        /// A single explanatory line (asleep, connecting, link error, empty).
        case placeholder(machine: SurfaceMachineID, CloudTreePlaceholder)
    }

    let id: String
    private(set) var kind: Kind
    private(set) var children: [CloudTreeNode]
    /// For workspace rows: everything the workspace holds, in the order it opens.
    private var explicitDragGroup: SurfaceResourceGroup?

    init(id: String, kind: Kind, children: [CloudTreeNode] = [], dragGroup: SurfaceResourceGroup? = nil) {
        self.id = id
        self.kind = kind
        self.children = children
        self.explicitDragGroup = dragGroup
    }

    var isExpandable: Bool { !children.isEmpty }

    /// The case of `kind` without its payload: what decides row height, menus,
    /// expandability and drag-ability. Two trees with equal structure signatures
    /// can be updated in place; a content-only change never needs `reloadData`.
    var structureTag: String {
        switch kind {
        case .machine: return "machine"
        case .localMachine: return "localMachine"
        case .terminalsPool: return "terminalsPool"
        case .displaysPool: return "displaysPool"
        case .workspacesGroup: return "workspacesGroup"
        case .workspace: return "workspace"
        case .localWorkspace: return "localWorkspace"
        case .terminal: return "terminal"
        case .display: return "display"
        case .browsersGroup: return "browsersGroup"
        case .browser: return "browser"
        case .portsGroup: return "portsGroup"
        case .port: return "port"
        case .placeholder: return "placeholder"
        }
    }

    /// Copies the values of an equal-structure rebuild into this node (NSOutlineView keeps
    /// the object it was handed; updating it in place keeps rows, expansion and the
    /// selection untouched). Children are adopted pairwise — callers guarantee the
    /// structure signature matched first.
    func adopt(from other: CloudTreeNode) {
        kind = other.kind
        explicitDragGroup = other.explicitDragGroup
        for (child, replacement) in zip(children, other.children) {
            child.adopt(from: replacement)
        }
    }

    var machine: SurfaceMachineID {
        switch kind {
        case .machine(let snapshot, _): return .cloud(snapshot.id)
        case .localMachine: return .local
        case .workspacesGroup(let machine), .browsersGroup(let machine), .portsGroup(let machine):
            return machine
        case .terminalsPool(let machine, _), .displaysPool(let machine, _):
            return machine
        case .workspace(let machine, _, _), .placeholder(let machine, _):
            return machine
        case .localWorkspace: return .local
        case .terminal(let row): return row.resource.machine
        case .display(let resource), .port(let resource): return resource.machine
        case .browser(let row): return row.resource.machine
        }
    }

    var isMachineRow: Bool {
        switch kind {
        case .machine, .localMachine: return true
        default: return false
        }
    }

    /// The text a quick-search (`/`) matches against.
    var searchableTitle: String {
        switch kind {
        case .machine(let machine, _): return machine.displayName
        case .localMachine(let row): return row.name
        case .terminalsPool: return String(localized: "cloudTree.group.terminals", defaultValue: "Terminals")
        case .displaysPool: return String(localized: "cloudTree.group.displays", defaultValue: "Displays")
        case .workspacesGroup: return String(localized: "cloudTree.group.workspaces", defaultValue: "Workspaces")
        case .workspace(_, let workspace, _): return workspace.name
        case .localWorkspace(let row): return row.title
        case .terminal(let row): return row.resource.title
        case .display(let resource): return resource.title.isEmpty ? String(localized: "cloudTree.node.desktop", defaultValue: "Desktop") : resource.title
        case .browsersGroup: return String(localized: "cloudTree.group.browsers", defaultValue: "Browsers")
        case .browser(let row): return row.resource.title
        case .portsGroup: return String(localized: "cloudTree.group.ports", defaultValue: "Ports")
        case .port(let resource): return resource.port.map(String.init) ?? resource.title
        case .placeholder(_, let placeholder): return placeholder.text
        }
    }

    /// What dragging this row into the main view projects: a single resource wrapped as a
    /// one-element group, or a workspace's whole collection (terminals, then browsers).
    /// Machine rows and group headers only organize and are not draggable.
    var dragGroup: SurfaceResourceGroup? {
        if let explicitDragGroup { return explicitDragGroup.isEmpty ? nil : explicitDragGroup }
        return dragResource.map { SurfaceResourceGroup(single: $0) }
    }

    /// The single resource a leaf row stands for; nil for workspace rows and headers.
    var dragResource: SurfaceResource? {
        switch kind {
        case .terminal(let row): return row.resource
        case .browser(let row): return row.resource
        case .display(let resource), .port(let resource): return resource
        case .machine, .localMachine, .terminalsPool, .displaysPool, .workspacesGroup, .workspace, .localWorkspace, .browsersGroup, .portsGroup, .placeholder:
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

/// This Mac's header row.
struct CloudTreeLocalMachineRow: Equatable {
    let name: String
    let terminalCount: Int
    let browserCount: Int
}

/// A local workspace row: the workspace that projects the terminals beneath it.
struct CloudTreeLocalWorkspaceRow: Equatable {
    let workspaceID: UUID
    let title: String
    let terminalCount: Int
    let isSelected: Bool
}

/// A terminal row: the resource plus whether a local pane shows it right now.
/// `viewBadge` is the number of daemon tabs showing the terminal, rendered on
/// pool rows only (nil hides the badge: local terminals, workspace pointer rows).
struct CloudTreeTerminalRow: Equatable {
    let resource: SurfaceResource
    let isOpen: Bool
    var viewBadge: Int?
}

/// A browser row (this Mac's browser panes, or a cloud machine's browsers).
struct CloudTreeBrowserRow: Equatable {
    let resource: SurfaceResource
    let isOpen: Bool
    /// Title of the local workspace showing it, when known.
    let workspaceTitle: String?
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

/// A local workspace, in sidebar order, for grouping this Mac's terminals.
struct CloudTreeLocalWorkspace: Equatable {
    let id: UUID
    let title: String
    let isSelected: Bool
}

/// Pure assembly of outline nodes from the fleet rows and the catalog snapshot.
/// Order: This Mac (local workspaces → terminals; Browsers) first, then every
/// cloud machine (Terminals pool; Displays pool; Workspaces → workspace →
/// pointer rows; Browsers); ports stay out of the tree for now, and a machine
/// without a connected link gets a placeholder child instead of the pools.
enum CloudTreeNodeBuilder {
    /// Whether the tree shows this Mac's own terminals and browsers. Off for now —
    /// the Machines panel is the cloud fleet; this Mac's surfaces already live in the
    /// sidebar — and the gate stays so the mixed tree remains one flip away.
    nonisolated(unsafe) static var includesLocalMachine = false

    static func nodes(
        machines: [MachineSnapshot],
        snapshot: SurfaceCatalogSnapshot,
        localWorkspaces: [CloudTreeLocalWorkspace],
        includeLocalMachine: Bool = CloudTreeNodeBuilder.includesLocalMachine
    ) -> [CloudTreeNode] {
        var nodes: [CloudTreeNode] = []
        if includeLocalMachine, let local = snapshot.machines.first(where: { $0.id.isLocal }) {
            nodes.append(localMachineNode(info: local, snapshot: snapshot, localWorkspaces: localWorkspaces))
        }
        let infoByMachine = Dictionary(snapshot.machines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        for machine in machines {
            seen.insert(machine.id)
            let info = infoByMachine[.cloud(machine.id)]
            nodes.append(CloudTreeNode(
                id: nodeID(machine: .cloud(machine.id)),
                kind: .machine(machine, info),
                children: cloudChildren(machine: .cloud(machine.id), info: info, snapshot: snapshot)
            ))
        }
        // Machines the catalog knows but the fleet list has not returned yet (or
        // returned under another name) still get a row so their surfaces are reachable.
        for info in snapshot.machines where !info.id.isLocal {
            guard let id = info.id.cloudMachineID, !seen.contains(id) else { continue }
            let placeholderSnapshot = MachineSnapshot(
                id: id,
                provider: "",
                image: info.image ?? "",
                isDesktop: info.hasDesktop,
                activity: MachineSnapshotBuilder.activity(fromStatus: info.status),
                createdAt: nil,
                label: info.name == id ? nil : info.name
            )
            nodes.append(CloudTreeNode(
                id: nodeID(machine: info.id),
                kind: .machine(placeholderSnapshot, info),
                children: cloudChildren(machine: info.id, info: info, snapshot: snapshot)
            ))
        }
        return nodes
    }

    /// True when `nodes(machines:snapshot:localWorkspaces:)` would produce no
    /// rows. The panel swaps the outline for its empty state on this; it must
    /// mirror `nodes` exactly (local catalog entries only count while
    /// `includesLocalMachine` is on), or a fresh account renders a blank
    /// outline instead of the empty state.
    static func isEmpty(
        machines: [MachineSnapshot],
        snapshot: SurfaceCatalogSnapshot,
        includeLocalMachine: Bool = CloudTreeNodeBuilder.includesLocalMachine
    ) -> Bool {
        guard machines.isEmpty else { return false }
        return !snapshot.machines.contains { includeLocalMachine || !$0.id.isLocal }
    }

    static func nodeID(machine: SurfaceMachineID) -> String { "machine:\(machine.rawValue)" }
    static func nodeID(terminalsPool machine: SurfaceMachineID) -> String { "machine:\(machine.rawValue)/terminals" }
    static func nodeID(displaysPool machine: SurfaceMachineID) -> String { "machine:\(machine.rawValue)/displays" }
    static func nodeID(workspacesGroup machine: SurfaceMachineID) -> String { "machine:\(machine.rawValue)/workspaces" }
    static func nodeID(workspace: String, machine: SurfaceMachineID) -> String { "machine:\(machine.rawValue)/ws/\(workspace)" }
    static func nodeID(resource: SurfaceResourceID) -> String { "resource:\(resource.rawValue)" }
    /// A pointer row: the same resource can sit under several workspaces (and the pool),
    /// so each row's identity carries the workspace it points from — otherwise expansion,
    /// selection and drag would collapse onto one row.
    static func nodeID(resource: SurfaceResourceID, inRemoteWorkspace workspaceID: String) -> String {
        "machine:\(resource.machine.rawValue)/ws/\(workspaceID)/resource:\(resource.rawValue)"
    }
    static func nodeID(browsersGroup machine: SurfaceMachineID) -> String { "machine:\(machine.rawValue)/browsers" }
    static func nodeID(portsGroup machine: SurfaceMachineID) -> String { "machine:\(machine.rawValue)/ports" }
    static func nodeID(placeholder machine: SurfaceMachineID) -> String { "machine:\(machine.rawValue)/placeholder" }

    // MARK: This Mac

    private static func localMachineNode(
        info: SurfaceMachineInfo,
        snapshot: SurfaceCatalogSnapshot,
        localWorkspaces: [CloudTreeLocalWorkspace]
    ) -> CloudTreeNode {
        let resources = snapshot.resources(on: .local)
        let terminals = resources.filter { $0.kind == .terminal }
        let browsers = resources.filter { $0.kind == .browser }
        let workspaceOf: (SurfaceResourceID) -> UUID? = { id in snapshot.projections(of: id).first?.workspaceID }
        let titles = Dictionary(localWorkspaces.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })

        var terminalsByWorkspace: [UUID: [SurfaceResource]] = [:]
        var unplaced: [SurfaceResource] = []
        for terminal in terminals {
            if let workspaceID = workspaceOf(terminal.id) {
                terminalsByWorkspace[workspaceID, default: []].append(terminal)
            } else {
                unplaced.append(terminal)
            }
        }
        // Sidebar order first; workspaces the sidebar list did not mention come last.
        var orderedWorkspaces = localWorkspaces.filter { terminalsByWorkspace[$0.id] != nil }
        let known = Set(orderedWorkspaces.map(\.id))
        for workspaceID in terminalsByWorkspace.keys.sorted(by: { $0.uuidString < $1.uuidString }) where !known.contains(workspaceID) {
            orderedWorkspaces.append(CloudTreeLocalWorkspace(id: workspaceID, title: titles[workspaceID] ?? "", isSelected: false))
        }

        var children: [CloudTreeNode] = orderedWorkspaces.map { workspace in
            let projected = terminalsByWorkspace[workspace.id] ?? []
            let title = workspace.title.isEmpty
                ? String(localized: "cloudTree.localWorkspace.untitled", defaultValue: "Workspace")
                : workspace.title
            let projectedBrowsers = browsers.filter { workspaceOf($0.id) == workspace.id }
            return CloudTreeNode(
                id: nodeID(workspace: workspace.id.uuidString, machine: .local),
                kind: .localWorkspace(CloudTreeLocalWorkspaceRow(
                    workspaceID: workspace.id,
                    title: title,
                    terminalCount: projected.count,
                    isSelected: workspace.isSelected
                )),
                children: projected.map { terminalNode($0, snapshot: snapshot) },
                dragGroup: SurfaceResourceGroup(title: title, resources: (projected + projectedBrowsers).map(\.id))
            )
        }
        children.append(contentsOf: unplaced.map { terminalNode($0, snapshot: snapshot) })
        if children.isEmpty {
            children.append(placeholder(.local, text: String(localized: "cloudTree.placeholder.noLocalTerminals", defaultValue: "No terminals open"), style: .dimmed))
        }
        if !browsers.isEmpty {
            children.append(CloudTreeNode(
                id: nodeID(browsersGroup: .local),
                kind: .browsersGroup(machine: .local),
                children: browsers.map { browser in
                    CloudTreeNode(
                        id: nodeID(resource: browser.id),
                        kind: .browser(CloudTreeBrowserRow(
                            resource: browser,
                            isOpen: snapshot.isOpen(browser.id),
                            workspaceTitle: workspaceOf(browser.id).flatMap { titles[$0] }
                        ))
                    )
                }
            ))
        }
        return CloudTreeNode(
            id: nodeID(machine: .local),
            kind: .localMachine(CloudTreeLocalMachineRow(name: info.name, terminalCount: terminals.count, browserCount: browsers.count)),
            children: children
        )
    }

    // MARK: Cloud machines

    private static func cloudChildren(machine: SurfaceMachineID, info: SurfaceMachineInfo?, snapshot: SurfaceCatalogSnapshot) -> [CloudTreeNode] {
        // The catalog has not registered this machine yet: nothing to expand.
        guard let info else { return [] }
        var children: [CloudTreeNode] = []
        let resources = snapshot.resources(on: machine)
        let terminals = resources.filter { $0.kind == .terminal }

        let displays = resources.filter { $0.kind == .display }
        // Displays exist even for a sleeping machine (opening one wakes it).
        let displaysNode: CloudTreeNode? = displays.isEmpty ? nil : CloudTreeNode(
            id: nodeID(displaysPool: machine),
            kind: .displaysPool(machine: machine, count: displays.count),
            children: displays.map { CloudTreeNode(id: nodeID(resource: $0.id), kind: .display($0)) }
        )

        switch info.linkState {
        case .asleep:
            children.append(placeholder(machine, text: String(localized: "cloudTree.placeholder.asleep", defaultValue: "Asleep \u{2014} open to wake"), style: .dimmed))
            if let displaysNode { children.append(displaysNode) }
        case .connecting:
            children.append(placeholder(machine, text: String(localized: "cloudTree.placeholder.connecting", defaultValue: "Connecting\u{2026}"), style: .connecting))
            if let displaysNode { children.append(displaysNode) }
        case .error:
            children.append(placeholder(machine, text: info.linkError ?? String(localized: "cloudTree.placeholder.linkError", defaultValue: "Link failed"), style: .error))
            if let displaysNode { children.append(displaysNode) }
        case .unavailable:
            children.append(placeholder(machine, text: String(localized: "cloudTree.placeholder.unavailable", defaultValue: "Sessions unavailable on this machine"), style: .dimmed))
            if let displaysNode { children.append(displaysNode) }
        case .connected, .notApplicable:
            // The pool: one row per terminal identity the machine owns, badge = views.
            children.append(CloudTreeNode(
                id: nodeID(terminalsPool: machine),
                kind: .terminalsPool(machine: machine, count: terminals.count),
                children: terminals.map { terminalNode($0, snapshot: snapshot, viewBadge: $0.remoteViews?.count) }
            ))
            if let displaysNode { children.append(displaysNode) }
            // Workspaces are pointer lists: a terminal shows under every workspace that
            // has a view of it; a zero-view terminal shows only in the pool. Empty
            // workspaces come from the machine info, so they still get a row.
            var byWorkspace: [String: (SurfaceRemoteWorkspace, [SurfaceResource])] = [:]
            for workspace in info.remoteWorkspaces ?? [] {
                byWorkspace[workspace.id] = (workspace, [])
            }
            for terminal in terminals {
                for workspace in terminal.remoteWorkspaces {
                    byWorkspace[workspace.id, default: (workspace, [])].1.append(terminal)
                }
            }
            let workspaces = byWorkspace.values.sorted { lhs, rhs in
                lhs.0.index != rhs.0.index ? lhs.0.index < rhs.0.index : lhs.0.id < rhs.0.id
            }
            if workspaces.isEmpty {
                children.append(placeholder(machine, text: String(localized: "cloudTree.placeholder.noWorkspaces", defaultValue: "No workspaces yet"), style: .dimmed))
            } else {
                // A workspace holds more than terminals: daemon browsers are tab content
                // too, so they get rows under every workspace that views them and ride
                // along in the workspace's open/drag group.
                var browsersByWorkspace: [String: [SurfaceResource]] = [:]
                for browser in resources where browser.kind == .browser {
                    for workspace in browser.remoteWorkspaces {
                        browsersByWorkspace[workspace.id, default: []].append(browser)
                    }
                }
                let workspaceNodes = workspaces.map { workspace, pointed in
                    let workspaceBrowsers = browsersByWorkspace[workspace.id] ?? []
                    return CloudTreeNode(
                        id: nodeID(workspace: workspace.id, machine: machine),
                        kind: .workspace(machine: machine, workspace, terminalCount: pointed.count),
                        children: pointed.map {
                            terminalNode($0, snapshot: snapshot, id: nodeID(resource: $0.id, inRemoteWorkspace: workspace.id))
                        } + workspaceBrowsers.map {
                            CloudTreeNode(
                                id: nodeID(resource: $0.id, inRemoteWorkspace: workspace.id),
                                kind: .browser(CloudTreeBrowserRow(resource: $0, isOpen: snapshot.isOpen($0.id), workspaceTitle: nil))
                            )
                        },
                        dragGroup: SurfaceResourceGroup(
                            title: workspace.name,
                            resources: (pointed + workspaceBrowsers).map(\.id)
                        )
                    )
                }
                children.append(CloudTreeNode(
                    id: nodeID(workspacesGroup: machine),
                    kind: .workspacesGroup(machine: machine),
                    children: workspaceNodes
                ))
            }
        }
        // Ports are out of the tree for now (still in the catalog: the CLI and
        // `cmux vm open <id>:port/<n>` keep working); the rows return with the
        // pool rework if they earn their place back.
        let browsers = resources.filter { $0.kind == .browser && $0.port == nil && $0.remoteViewCount == 0 }
        if !browsers.isEmpty {
            children.append(CloudTreeNode(
                id: nodeID(browsersGroup: machine),
                kind: .browsersGroup(machine: machine),
                children: browsers.map {
                    CloudTreeNode(id: nodeID(resource: $0.id), kind: .browser(CloudTreeBrowserRow(resource: $0, isOpen: snapshot.isOpen($0.id), workspaceTitle: nil)))
                }
            ))
        }
        return children
    }

    private static func terminalNode(
        _ resource: SurfaceResource,
        snapshot: SurfaceCatalogSnapshot,
        id: String? = nil,
        viewBadge: Int? = nil
    ) -> CloudTreeNode {
        CloudTreeNode(
            id: id ?? nodeID(resource: resource.id),
            kind: .terminal(CloudTreeTerminalRow(resource: resource, isOpen: snapshot.isOpen(resource.id), viewBadge: viewBadge))
        )
    }

    private static func placeholder(_ machine: SurfaceMachineID, text: String, style: CloudTreePlaceholder.Style) -> CloudTreeNode {
        CloudTreeNode(
            id: nodeID(placeholder: machine),
            kind: .placeholder(machine: machine, CloudTreePlaceholder(text: text, style: style))
        )
    }

    /// Depth-first flattening in display order (every node expanded); used by
    /// tests and by quick-search.
    static func flattened(_ nodes: [CloudTreeNode]) -> [CloudTreeNode] {
        nodes.flatMap { [$0] + flattened($0.children) }
    }

    /// Row identities, order and kinds — a change here needs `reloadData`.
    static func structureSignature(_ nodes: [CloudTreeNode]) -> [String] {
        flattened(nodes).map { "\($0.id)|\($0.structureTag)|\($0.children.count)" }
    }

    /// Everything a row displays — a change here with an equal structure signature is
    /// applied to the existing rows in place.
    static func contentSignature(_ nodes: [CloudTreeNode]) -> [String] {
        flattened(nodes).map { "\($0.id)|\(String(describing: $0.kind))|\(String(describing: $0.dragGroup))" }
    }
}
