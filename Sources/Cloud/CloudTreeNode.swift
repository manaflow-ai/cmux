import CmuxFoundation
import Foundation

/// One row of the Cloud outline, built from the surface catalog: this Mac or a
/// cloud machine, a group ("Workspaces", "Terminals", "Ports", "VNC Displays"), a workspace
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
        /// A machine being created (or whose create failed): the row that stands
        /// where the machine will appear, from the sheet's Create until the fleet
        /// list returns it. Never expandable, never a drag source.
        case pendingMachine(MachineCreateOperation)
        /// This Mac.
        case localMachine(CloudTreeLocalMachineRow)
        /// "Terminals" pool under a cloud machine: every terminal the machine owns, one
        /// row per identity, whatever workspaces (zero or more) show it.
        case terminalsPool(machine: SurfaceMachineID, count: Int)
        /// "VNC Displays" group under a cloud machine: one row per screen it exposes.
        case displaysPool(machine: SurfaceMachineID, count: Int)
        /// "Workspaces" group under a machine.
        case workspacesGroup(machine: SurfaceMachineID)
        /// A cmux-tui workspace on a cloud machine; its children are pointer rows into
        /// the machine's pools.
        /// `openIn`: the local workspace already showing this remote one (its open mark;
        /// clicking jumps there), else nil.
        case workspace(machine: SurfaceMachineID, SurfaceRemoteWorkspace, terminalCount: Int, openIn: UUID?)
        /// A local workspace, grouping the local terminals it projects.
        case localWorkspace(CloudTreeLocalWorkspaceRow)
        case terminal(CloudTreeTerminalRow)
        /// One VNC display of a machine. Under a remote workspace the row carries the
        /// local workspace already showing that remote workspace (the parent's openIn),
        /// so its open verb stays inside that workspace instead of jumping to a VNC
        /// pane elsewhere; pool rows carry nil and keep the global open-or-focus.
        case display(SurfaceResource, openIn: UUID?)
        /// "Browsers" group (this Mac).
        case browsersGroup(machine: SurfaceMachineID)
        case browser(CloudTreeBrowserRow)
        /// "Ports" group under a cloud machine.
        case portsGroup(machine: SurfaceMachineID)
        /// The resource plus the URL a click actually opens —
        /// `http://<private-ip>:<port>`, reachable over the WireGuard tunnel —
        /// or nil when the machine has no private address yet (public-only
        /// machines, or one this Mac hasn't attached to yet). Deliberately the
        /// raw address, never the `.internal` name: that name only resolves
        /// once `cmux vpn hosts` has synced `/etc/hosts`, so a link built from
        /// it would work only sometimes.
        case port(SurfaceResource, url: String?)
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
        case .pendingMachine: return "pendingMachine"
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
        // No machine exists yet; the id keeps the row addressable (drag
        // registries, debug logs) without colliding with a real machine.
        case .pendingMachine(let operation): return .cloud("pending:\(operation.id.uuidString)")
        case .localMachine: return .local
        case .workspacesGroup(let machine), .browsersGroup(let machine), .portsGroup(let machine):
            return machine
        case .terminalsPool(let machine, _), .displaysPool(let machine, _):
            return machine
        case .workspace(let machine, _, _, _), .placeholder(let machine, _):
            return machine
        case .localWorkspace: return .local
        case .terminal(let row): return row.resource.machine
        case .display(let resource, _): return resource.machine
        case .port(let resource, _): return resource.machine
        case .browser(let row): return row.resource.machine
        }
    }

    var isMachineRow: Bool {
        switch kind {
        case .machine, .localMachine, .pendingMachine: return true
        default: return false
        }
    }

    /// The text a quick-search (`/`) matches against.
    var searchableTitle: String {
        switch kind {
        case .machine(let machine, _): return machine.displayName
        case .pendingMachine(let operation): return operation.request.displayName
        case .localMachine(let row): return row.name
        case .terminalsPool: return String(localized: "cloudTree.group.terminals", defaultValue: "Terminals")
        case .displaysPool: return String(localized: "cloudTree.group.displays", defaultValue: "VNC Displays")
        case .workspacesGroup: return String(localized: "cloudTree.group.workspaces", defaultValue: "Workspaces")
        case .workspace(_, let workspace, _, _): return workspace.name
        case .localWorkspace(let row): return row.title
        case .terminal(let row): return row.resource.title
        case .display(let resource, _): return resource.title.isEmpty ? String(localized: "cloudTree.node.desktop", defaultValue: "Desktop") : resource.title
        case .browsersGroup: return String(localized: "cloudTree.group.browsers", defaultValue: "Browsers")
        case .browser(let row): return row.resource.title
        case .portsGroup: return String(localized: "cloudTree.group.ports", defaultValue: "Ports")
        case .port(let resource, let url): return url ?? resource.port.map(String.init) ?? resource.title
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

    /// Whether this row may start a native drag. Only terminals and displays
    /// leave the tree by drag; workspaces, browsers, ports, machines, and
    /// headers do not (their `dragGroup` still feeds open verbs and menus).
    var isDragSource: Bool {
        switch kind {
        case .terminal, .display: return true
        default: return false
        }
    }

    /// The single resource a leaf row stands for; nil for workspace rows and headers.
    var dragResource: SurfaceResource? {
        switch kind {
        case .terminal(let row): return row.resource
        case .browser(let row): return row.resource
        case .display(let resource, _), .port(let resource, _): return resource
        case .machine, .pendingMachine, .localMachine, .terminalsPool, .displaysPool, .workspacesGroup, .workspace, .localWorkspace, .browsersGroup, .portsGroup, .placeholder:
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
    /// A live terminal no daemon tab shows: out of every workspace's layout, so it
    /// is a Terminals-group row only, drawn greyed with a "detached" mark. Derived
    /// from the resource so lifecycle updates cannot leave a stale duplicate flag.
    /// Its verbs are a terminal's — a click re-attaches it in a pane, Kill Terminal ends it.
    var isDetached: Bool { resource.isDetachedTerminal }
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
/// cloud machine — one big machine hosting many cmux-tui workspaces, with four
/// groups: Workspaces → workspace → the terminals in its layout (always, the
/// machine's face), Ports, VNC Displays (one row per screen), and last, as its
/// own section, Terminals (every terminal the machine owns, always). A machine
/// without a connected link gets a placeholder child instead of Workspaces and
/// Terminals.
enum CloudTreeNodeBuilder {
    /// Whether the tree shows this Mac's own terminals and browsers. Off for now —
    /// the Machines panel is the cloud fleet; this Mac's surfaces already live in the
    /// sidebar — and the gate stays so the mixed tree remains one flip away.
    nonisolated(unsafe) static var includesLocalMachine = false

    /// Builds the ordered outline for a catalog snapshot and the current fleet list.
    /// The projection index is shared by every machine and row in this rebuild.
    static func nodes(
        machines: [MachineSnapshot],
        pendingCreates: [MachineCreateOperation] = [],
        snapshot: SurfaceCatalogSnapshot,
        localWorkspaces: [CloudTreeLocalWorkspace],
        includeLocalMachine: Bool = CloudTreeNodeBuilder.includesLocalMachine
    ) -> [CloudTreeNode] {
        // Build the projection index once for this immutable tree snapshot. Every
        // row can then answer its open-state with dictionary membership instead of
        // rescanning all projections (which matters when a machine owns many
        // terminals and the user has many local panes).
        let projectionsByResource = projectionIndex(snapshot)
        var nodes: [CloudTreeNode] = []
        if includeLocalMachine, let local = snapshot.machines.first(where: { $0.id.isLocal }) {
            nodes.append(localMachineNode(
                info: local,
                snapshot: snapshot,
                localWorkspaces: localWorkspaces,
                projectionsByResource: projectionsByResource
            ))
        }
        // Creates the person just started go first: they are what the person is
        // waiting on, and a failed one must not hide below a long fleet. A
        // create whose machine the fleet list or the catalog already returned
        // has a real row now and drops its stand-in (never the same machine
        // twice while the CLI is still opening it).
        for operation in pendingCreates where !operation.isSuperseded(by: machines, catalogMachines: snapshot.machines) {
            nodes.append(CloudTreeNode(id: nodeID(pendingCreate: operation.id), kind: .pendingMachine(operation)))
        }
        let infoByMachine = Dictionary(snapshot.machines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        for machine in machines {
            seen.insert(machine.id)
            let info = infoByMachine[.cloud(machine.id)]
            nodes.append(CloudTreeNode(
                id: nodeID(machine: .cloud(machine.id)),
                kind: .machine(machine, info),
                children: cloudChildren(
                    machine: .cloud(machine.id),
                    info: info,
                    snapshot: snapshot,
                    projectionsByResource: projectionsByResource
                )
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
                children: cloudChildren(
                    machine: info.id,
                    info: info,
                    snapshot: snapshot,
                    projectionsByResource: projectionsByResource
                )
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
        pendingCreates: [MachineCreateOperation] = [],
        snapshot: SurfaceCatalogSnapshot,
        includeLocalMachine: Bool = CloudTreeNodeBuilder.includesLocalMachine
    ) -> Bool {
        guard machines.isEmpty, pendingCreates.isEmpty else { return false }
        return !snapshot.machines.contains { includeLocalMachine || !$0.id.isLocal }
    }

    static func nodeID(machine: SurfaceMachineID) -> String { "machine:\(machine.rawValue)" }
    static func nodeID(pendingCreate id: UUID) -> String { "pending-machine:\(id.uuidString)" }
    static func nodeID(terminalsPool machine: SurfaceMachineID) -> String { "machine:\(machine.rawValue)/terminals" }
    static func nodeID(displaysPool machine: SurfaceMachineID) -> String { "machine:\(machine.rawValue)/displays" }
    /// The "No terminals yet" line under an empty machine's Terminals group.
    static func nodeID(terminalsPlaceholder machine: SurfaceMachineID) -> String { "machine:\(machine.rawValue)/terminals/placeholder" }
    static func nodeID(workspacesGroup machine: SurfaceMachineID) -> String { "machine:\(machine.rawValue)/workspaces" }
    /// The "No workspaces yet" line under an empty machine's Workspaces group.
    static func nodeID(workspacesPlaceholder machine: SurfaceMachineID) -> String { "machine:\(machine.rawValue)/workspaces/placeholder" }
    static func nodeID(workspace: String, machine: SurfaceMachineID) -> String { "machine:\(machine.rawValue)/ws/\(workspace)" }
    /// The local workspace that shows a remote workspace: the one holding the most of its
    /// members' panes (at least one). Nil when none of them is open anywhere.
    static func localWorkspaceShowing(_ members: [SurfaceResourceID], snapshot: SurfaceCatalogSnapshot) -> UUID? {
        guard !members.isEmpty else { return nil }
        return localWorkspaceShowing(members, projectionIndex: projectionIndex(snapshot))
    }

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

    /// Builds the local machine branch, grouping projected terminals by local workspace.
    private static func localMachineNode(
        info: SurfaceMachineInfo,
        snapshot: SurfaceCatalogSnapshot,
        localWorkspaces: [CloudTreeLocalWorkspace],
        projectionsByResource: [SurfaceResourceID: [UUID: Int]]
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
                children: projected.map { terminalNode($0, projectionsByResource: projectionsByResource) },
                dragGroup: SurfaceResourceGroup(title: title, resources: (projected + projectedBrowsers).map(\.id))
            )
        }
        children.append(contentsOf: unplaced.map { terminalNode($0, projectionsByResource: projectionsByResource) })
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
                            isOpen: projectionsByResource[browser.id] != nil,
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

    /// `http://<name>.internal:<port>` when the machine has a private address
    /// (the internal name resolves only through the app's DNS override, so
    /// this is only offered when we can name and reach it), else the bare
    /// `http://<ip>:<port>`, else nil.
    private static func portURL(machine: SurfaceMachineID, info: SurfaceMachineInfo?, port: Int?) -> String? {
        guard let port, let address = info?.privateAddress else { return nil }
        // Cloud machines only: the local Mac has no private-network address to
        // begin with, so it never reaches here with one.
        guard machine.isLocal == false else { return nil }
        return CmuxInternalHostnames.directPortURL(privateAddress: address, port: port)
    }

    /// Builds one cloud-machine branch in the canonical Workspaces, Ports,
    /// VNC Displays, Terminals order.
    private static func cloudChildren(
        machine: SurfaceMachineID,
        info: SurfaceMachineInfo?,
        snapshot: SurfaceCatalogSnapshot,
        projectionsByResource: [SurfaceResourceID: [UUID: Int]]
    ) -> [CloudTreeNode] {
        // The catalog has not registered this machine yet: nothing to expand.
        guard let info else { return [] }
        var children: [CloudTreeNode] = []
        let resources = snapshot.resources(on: machine)
        let terminals = resources.filter { $0.kind == .terminal }
        let displays = resources.filter { $0.kind == .display }

        switch info.linkState {
        case .asleep:
            children.append(placeholder(machine, text: String(localized: "cloudTree.placeholder.asleep", defaultValue: "Asleep \u{2014} open to wake"), style: .dimmed))
        case .connecting:
            children.append(placeholder(machine, text: String(localized: "cloudTree.placeholder.connecting", defaultValue: "Connecting\u{2026}"), style: .connecting))
        case .error:
            children.append(placeholder(machine, text: info.linkError ?? String(localized: "cloudTree.placeholder.linkError", defaultValue: "Link failed"), style: .error))
        case .unavailable:
            children.append(placeholder(machine, text: String(localized: "cloudTree.placeholder.unavailable", defaultValue: "Sessions unavailable on this machine"), style: .dimmed))
        case .connected, .notApplicable:
            // One machine, many workspaces: the Workspaces group leads and is
            // always its own row (never folded into a lone workspace), so its
            // "+" — the New Workspace verb — is one click away on a fresh
            // machine with a single workspace as much as on a busy one.
            children.append(workspacesGroupNode(
                machine: machine,
                info: info,
                resources: resources,
                displays: displays,
                projectionsByResource: projectionsByResource
            ))
        }
        // Ports: one row per listening port, titled as the URL a person would
        // paste (`http://<private-ip>:<port>`) when the machine has a private
        // address; the bare `:<port>` otherwise. Click opens it as a browser
        // pane; the row's menu copies the link.
        // A regular workspace-tab browser can happen to point at a localhost
        // port too (`browser.port` derives from the URL). Only orphan port
        // rows belong here — one with a real workspace tab already shows
        // under that workspace and would otherwise be listed twice. A daemon
        // browser with neither a tab nor a port has no group of its own: the
        // four groups are the machine's whole layout (it stays in the catalog
        // for `cmux surface ls`).
        let portBrowsers = resources
            .filter { $0.kind == .browser && $0.port != nil && $0.remoteWorkspaces.isEmpty }
            .sorted { ($0.port ?? 0) < ($1.port ?? 0) }
        if !portBrowsers.isEmpty {
            children.append(CloudTreeNode(
                id: nodeID(portsGroup: machine),
                kind: .portsGroup(machine: machine),
                children: portBrowsers.map {
                    CloudTreeNode(id: nodeID(resource: $0.id), kind: .port($0, url: portURL(machine: machine, info: info, port: $0.port)))
                }
            ))
        }
        // VNC Displays: one row per screen the machine exposes (`display:1`, …).
        // Listed whatever the link state — opening one wakes a sleeping machine,
        // and the desktop never needed the session link to begin with.
        if !displays.isEmpty {
            children.append(CloudTreeNode(
                id: nodeID(displaysPool: machine),
                kind: .displaysPool(machine: machine, count: displays.count),
                children: displays.map { CloudTreeNode(id: nodeID(resource: $0.id), kind: .display($0, openIn: nil)) }
            ))
        }
        // Last, its own section: every terminal the machine owns, flat (the
        // workspace rows above point into it, detached ones live only here);
        // always present on a connected machine, so its "+" — New Terminal —
        // is there on an empty machine too.
        switch info.linkState {
        case .connected, .notApplicable:
            children.append(terminalsGroupNode(
                machine: machine,
                terminals: terminals,
                projectionsByResource: projectionsByResource
            ))
        case .asleep, .connecting, .error, .unavailable:
            break
        }
        return children
    }

    /// The Workspaces group: one row per cmux-tui workspace on the machine, each a
    /// pointer list into the Terminals group — a terminal shows under every
    /// workspace that views it, while a zero-view terminal appears only in the
    /// Terminals group; an empty workspace
    /// (from the machine info) still gets a row. An empty machine keeps the group
    /// too, with a placeholder child, so "+" is how its first workspace is made.
    private static func workspacesGroupNode(
        machine: SurfaceMachineID,
        info: SurfaceMachineInfo,
        resources: [SurfaceResource],
        displays: [SurfaceResource],
        projectionsByResource: [SurfaceResourceID: [UUID: Int]]
    ) -> CloudTreeNode {
        // One pass over the catalog for every workspace's members and one over the
        // projections for the open marks; each row is then dictionary reads.
        let membersByWorkspace = remoteWorkspaceMembersByWorkspace(resources: resources)
        var rows = remoteWorkspaces(info: info, resources: resources).map { workspace -> CloudTreeNode in
            // A workspace holds more than terminals: daemon browsers are tab
            // content too, and a workspace that points at the machine's screen
            // shows it and opens/drags it with its terminals.
            let members = membersByWorkspace[workspace.id] ?? .none
            // Only the layout: a terminal whose tab in the workspace is gone has
            // left the workspace (it is still running — the Terminals group lists
            // it greyed as detached), so no row for it lingers here.
            // Every workspace can reach the machine's screen: when no view pins a
            // display yet, the machine's displays still show under the workspace,
            // so its terminals and its desktop open from one place. Implicit rows
            // stay out of `members`/dragGroup — only real pointers travel with the
            // workspace's open/drag group.
            let shownDisplays = members.displays.isEmpty ? displays : members.displays
            let openInLocal = localWorkspaceShowing(members.ids, projectionIndex: projectionsByResource)
            return CloudTreeNode(
                id: nodeID(workspace: workspace.id, machine: machine),
                kind: .workspace(machine: machine, workspace, terminalCount: members.terminals.count, openIn: openInLocal),
                children: members.terminals.map {
                    terminalNode(
                        $0,
                        projectionsByResource: projectionsByResource,
                        id: nodeID(resource: $0.id, inRemoteWorkspace: workspace.id)
                    )
                } + members.browsers.map {
                    CloudTreeNode(
                        id: nodeID(resource: $0.id, inRemoteWorkspace: workspace.id),
                        kind: .browser(CloudTreeBrowserRow(
                            resource: $0,
                            isOpen: projectionsByResource[$0.id] != nil,
                            workspaceTitle: nil
                        ))
                    )
                } + shownDisplays.map {
                    CloudTreeNode(id: nodeID(resource: $0.id, inRemoteWorkspace: workspace.id), kind: .display($0, openIn: openInLocal))
                },
                dragGroup: SurfaceResourceGroup(title: workspace.name, resources: members.ids)
            )
        }
        if rows.isEmpty {
            rows.append(CloudTreeNode(
                id: nodeID(workspacesPlaceholder: machine),
                kind: .placeholder(machine: machine, CloudTreePlaceholder(
                    text: String(localized: "cloudTree.placeholder.noWorkspaces", defaultValue: "No workspaces yet"),
                    style: .dimmed
                ))
            ))
        }
        return CloudTreeNode(
            id: nodeID(workspacesGroup: machine),
            kind: .workspacesGroup(machine: machine),
            children: rows
        )
    }

    /// The Terminals group, the machine's last section: every terminal it owns,
    /// one row per identity whatever workspaces show it (badge = daemon tabs), a
    /// zero-view one greyed as detached. Always present under a connected machine
    /// — its "+" is New Terminal — with a placeholder child when there is none yet.
    private static func terminalsGroupNode(
        machine: SurfaceMachineID,
        terminals: [SurfaceResource],
        projectionsByResource: [SurfaceResourceID: [UUID: Int]]
    ) -> CloudTreeNode {
        var rows = terminals.map {
            terminalNode(
                $0,
                projectionsByResource: projectionsByResource,
                viewBadge: $0.remoteViews?.count
            )
        }
        if rows.isEmpty {
            rows.append(CloudTreeNode(
                id: nodeID(terminalsPlaceholder: machine),
                kind: .placeholder(machine: machine, CloudTreePlaceholder(
                    text: String(localized: "cloudTree.placeholder.noTerminals", defaultValue: "No terminals yet"),
                    style: .dimmed
                ))
            ))
        }
        return CloudTreeNode(
            id: nodeID(terminalsPool: machine),
            kind: .terminalsPool(machine: machine, count: terminals.count),
            children: rows
        )
    }

    /// Builds one terminal row using the snapshot's precomputed projection index.
    /// `viewBadge` is shown only by the flat machine Terminals group; workspace
    /// pointer rows leave it nil.
    private static func terminalNode(
        _ resource: SurfaceResource,
        projectionsByResource: [SurfaceResourceID: [UUID: Int]],
        id: String? = nil,
        viewBadge: Int? = nil
    ) -> CloudTreeNode {
        CloudTreeNode(
            id: id ?? nodeID(resource: resource.id),
            kind: .terminal(CloudTreeTerminalRow(
                resource: resource,
                isOpen: projectionsByResource[resource.id] != nil,
                viewBadge: viewBadge
            ))
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
