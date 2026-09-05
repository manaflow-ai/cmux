import CmuxFoundation
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
        /// One VNC display placement. Under a remote workspace the row carries both the
        /// local workspace already showing that remote workspace and the exact daemon tab
        /// that owns the display. Pool rows carry nil values and use global open-or-focus.
        case display(SurfaceResource, openIn: UUID?, remoteView: SurfaceRemoteView?)
        /// "Browsers" group (this Mac).
        case browsersGroup(machine: SurfaceMachineID)
        case browser(CloudTreeBrowserRow)
        /// "Ports" group under a cloud machine.
        case portsGroup(machine: SurfaceMachineID)
        /// The resource plus the URL a click actually opens —
        /// `http://<private-ip>:<port>`, reachable over the WireGuard tunnel —
        /// or nil when the machine has no private address yet. Deliberately the
        /// raw address: Cloud browser URLs need no DNS or `/etc/hosts` changes.
        /// `openIn` is the local workspace already showing the owning remote
        /// workspace, when this is a workspace pointer rather than the machine
        /// pool row. Keeping it on the node prevents a click from consulting
        /// the globally selected workspace after a refresh.
        case port(SurfaceResource, url: String?, openIn: UUID?)
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
        case .display(let resource, _, _): return resource.machine
        case .port(let resource, _, _): return resource.machine
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
        case .terminal(let row): return row.displayTitle
        case .display(let resource, _, let remoteView):
            let title = remoteView?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let title, !title.isEmpty { return title }
            return resource.title.isEmpty ? String(localized: "cloudTree.node.desktop", defaultValue: "Desktop") : resource.title
        case .browsersGroup: return String(localized: "cloudTree.group.browsers", defaultValue: "Browsers")
        case .browser(let row): return row.resource.title
        case .portsGroup: return String(localized: "cloudTree.group.ports", defaultValue: "Ports")
        case .port(let resource, let url, _):
            return url ?? (resource.id.forwardedPort ?? resource.port).map(String.init) ?? resource.title
        case .placeholder(_, let placeholder): return placeholder.text
        }
    }

    /// What dragging this row into the main view projects: a single resource wrapped as a
    /// one-element group, or a workspace's whole collection (terminals, then browsers).
    /// Machine rows and group headers only organize and are not draggable.
    var dragGroup: SurfaceResourceGroup? {
        if let explicitDragGroup { return explicitDragGroup.isEmpty ? nil : explicitDragGroup }
        if case .terminal(let row) = kind,
           let view = row.remoteView {
            // A workspace pointer carries one exact daemon placement. Preserve it
            // in the drag payload so later opens and renames keep that identity.
            return SurfaceResourceGroup(
                title: row.displayTitle,
                placements: [SurfaceResourcePlacement(resource: row.resource.id, remoteView: view)],
                remoteWorkspaceID: view.workspace.id
            )
        }
        if case .browser(let row) = kind,
           let view = row.remoteView {
            return SurfaceResourceGroup(
                title: row.resource.title,
                placements: [SurfaceResourcePlacement(resource: row.resource.id, remoteView: view)],
                remoteWorkspaceID: view.workspace.id
            )
        }
        if case .display(let resource, _, let view) = kind,
           let view {
            return SurfaceResourceGroup(
                title: resource.title,
                placements: [SurfaceResourcePlacement(resource: resource.id, remoteView: view)],
                remoteWorkspaceID: view.workspace.id
            )
        }
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
        case .display(let resource, _, _), .port(let resource, _, _): return resource
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
    /// The exact daemon tab represented by a workspace pointer row. Pool rows
    /// leave this nil because one terminal may have several placement names.
    var remoteView: SurfaceRemoteView? = nil

    /// A terminal resource has one process title, but each daemon tab can have
    /// its own user name. Workspace rows must render the placement name, or a
    /// rename in one tab appears to change every tab in the tree.
    var displayTitle: String {
        if let name = remoteView?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return resource.title
    }

    /// True when no daemon tab currently contains this terminal.
    var isDetached: Bool { resource.isDetachedTerminal }
}

/// A browser row (this Mac's browser panes, or a cloud machine's browsers).
struct CloudTreeBrowserRow: Equatable {
    let resource: SurfaceResource
    let isOpen: Bool
    /// Title of the local workspace showing it, when known.
    let workspaceTitle: String?
    /// Exact daemon tab represented by a workspace pointer. Browser resources
    /// currently have one tab in the public schema, but retaining the same
    /// placement contract as terminals keeps future multi-view browsers safe.
    var remoteView: SurfaceRemoteView? = nil
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
/// cloud machine, with Workspaces first, then Ports, VNC Displays, and the
/// complete Terminals process index. Workspace children preserve exact daemon
/// tab placement identities. A machine without a connected link keeps cached
/// pool rows beside its status placeholder.
enum CloudTreeNodeBuilder {
    /// Whether the tree shows this Mac's own terminals and browsers. Off for now —
    /// the Machines panel is the cloud fleet; this Mac's surfaces already live in the
    /// sidebar — and the gate stays so the mixed tree remains one flip away.
    nonisolated(unsafe) static var includesLocalMachine = false

    /// A row is a placement, not only a resource. The same terminal can occur
    /// in two tabs of one workspace, and those tabs can have different names.
    private struct RemoteResourcePlacement {
        let resource: SurfaceResource
        let workspace: SurfaceRemoteWorkspace
        let view: SurfaceRemoteView?
    }

    private struct RemoteWorkspaceRows {
        var workspace: SurfaceRemoteWorkspace
        var terminals: [RemoteResourcePlacement] = []
        var browsers: [RemoteResourcePlacement] = []
        var displays: [RemoteResourcePlacement] = []
    }

    private struct RemotePlacementIdentity: Hashable {
        let resource: SurfaceResourceID
        let workspaceID: String
        let tabID: String?
    }

    private struct RemoteWorkspaceIdentity: Hashable {
        let resource: SurfaceResourceID
        let workspaceID: String
    }

    /// Indexes local projections by their complete remote placement and by
    /// open-state identity. The cloud tree is rebuilt often, so neither
    /// `localWorkspaceShowing` nor leaf rows should rescan every projection.
    private struct LocalProjectionIndex {
        private var exact: [RemotePlacementIdentity: [UUID]] = [:]
        /// A projection from a provider that does not model tabs. This is only
        /// used when the current resource also has no view metadata, so it
        /// cannot claim an arbitrary tab in a multi-view resource.
        private var workspaceOnly: [RemoteWorkspaceIdentity: [UUID]] = [:]
        private var legacy: [SurfaceResourceID: [UUID]] = [:]
        private var openResources: Set<SurfaceResourceID> = []
        private var openPlacements: Set<RemotePlacementIdentity> = []
        private var workspaceCountsByResource: [SurfaceResourceID: [UUID: Int]] = [:]

        init(snapshot: SurfaceCatalogSnapshot) {
            let resourceByID = Dictionary(
                snapshot.resources.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var projectionCountByResource: [SurfaceResourceID: Int] = [:]
            for projection in snapshot.projections {
                projectionCountByResource[projection.resource, default: 0] += 1
            }

            var singleViewResources = Set<SurfaceResourceID>()
            for resource in snapshot.resources where resource.remoteViews?.count == 1 {
                singleViewResources.insert(resource.id)
            }

            for projection in snapshot.projections {
                openResources.insert(projection.resource)
                workspaceCountsByResource[projection.resource, default: [:]][projection.workspaceID, default: 0] += 1
                if let remoteWorkspaceID = projection.remoteWorkspaceID {
                    if let remoteTabID = projection.remoteTabID, !remoteTabID.isEmpty {
                        let identity = RemotePlacementIdentity(
                            resource: projection.resource,
                            workspaceID: remoteWorkspaceID,
                            tabID: remoteTabID
                        )
                        openPlacements.insert(identity)
                        exact[identity, default: []].append(projection.workspaceID)
                    } else if let views = resourceByID[projection.resource]?.remoteViews {
                        // Intermediate builds persisted the workspace id before
                        // they persisted tab ids. Recover the tab only when the
                        // current graph has one unambiguous view in that
                        // workspace. Multiple views fail closed.
                        let matchingViews = views.filter {
                            $0.workspace.id == remoteWorkspaceID && !$0.tabID.isEmpty
                        }
                        if matchingViews.count == 1, let view = matchingViews.first {
                            let identity = RemotePlacementIdentity(
                                resource: projection.resource,
                                workspaceID: remoteWorkspaceID,
                                tabID: view.tabID
                            )
                            openPlacements.insert(identity)
                            exact[identity, default: []].append(projection.workspaceID)
                        }
                    } else if projection.remoteTabID?.isEmpty != false {
                        // A provider with no view model can still identify the
                        // remote workspace. Keep this weaker identity separate
                        // from exact tab identities and use it only for that
                        // same workspace.
                        let identity = RemoteWorkspaceIdentity(
                            resource: projection.resource,
                            workspaceID: remoteWorkspaceID
                        )
                        workspaceOnly[identity, default: []].append(projection.workspaceID)
                    }
                } else if let remoteTabID = projection.remoteTabID,
                          !remoteTabID.isEmpty,
                          let view = resourceByID[projection.resource]?.remoteViews?.first(where: { $0.tabID == remoteTabID }) {
                    // A short-lived archive can contain a tab id without its
                    // workspace id. The current view supplies that missing
                    // coordinate when the tab id is unique.
                    let identity = RemotePlacementIdentity(
                        resource: projection.resource,
                        workspaceID: view.workspace.id,
                        tabID: remoteTabID
                    )
                    openPlacements.insert(identity)
                    exact[identity, default: []].append(projection.workspaceID)
                } else if projection.remoteTabID?.isEmpty != false,
                          projectionCountByResource[projection.resource] == 1,
                          singleViewResources.contains(projection.resource) {
                    // A pre-placement session record has no remote coordinates.
                    // Keep the narrow compatibility rule from the old scan, but
                    // precompute it once so it cannot become a hot-path scan.
                    legacy[projection.resource, default: []].append(projection.workspaceID)
                }
            }
        }

        func isOpen(_ resource: SurfaceResourceID, remoteView: SurfaceRemoteView?) -> Bool {
            guard let remoteView else { return openResources.contains(resource) }
            let identity = RemotePlacementIdentity(
                resource: resource,
                workspaceID: remoteView.workspace.id,
                tabID: remoteView.tabID
            )
            if openPlacements.contains(identity) { return true }
            if workspaceOnly[RemoteWorkspaceIdentity(
                resource: resource,
                workspaceID: remoteView.workspace.id
            )] != nil { return true }
            // The oldest session records have neither remote coordinate. The
            // initializer keeps them only when this resource has exactly one
            // projection and one current view, so this fallback is unambiguous.
            return legacy[resource] != nil
        }

        /// Returns the local workspace with the most projections of one resource.
        /// Resource identity is correct for pool rows, which do not represent one
        /// remote tab placement.
        func localWorkspaceShowing(resource: SurfaceResourceID) -> UUID? {
            workspaceCountsByResource[resource]?.max { lhs, rhs in
                lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key.uuidString > rhs.key.uuidString
            }?.key
        }

        func localWorkspaceShowing(
            remoteWorkspaceID: String,
            placements: [SurfaceResourcePlacement]
        ) -> UUID? {
            let wanted = Set(placements.compactMap { placement -> RemotePlacementIdentity? in
                guard placement.remoteWorkspaceID == remoteWorkspaceID else { return nil }
                return RemotePlacementIdentity(
                    resource: placement.resource,
                    workspaceID: remoteWorkspaceID,
                    tabID: placement.remoteTabID
                )
            })
            guard !wanted.isEmpty else { return nil }

            var placementCountByResource: [SurfaceResourceID: Int] = [:]
            for identity in wanted {
                placementCountByResource[identity.resource, default: 0] += 1
            }
            var counts: [UUID: Int] = [:]
            for identity in wanted {
                for workspaceID in exact[identity] ?? [] {
                    counts[workspaceID, default: 0] += 1
                }
                if placementCountByResource[identity.resource] == 1 {
                    for workspaceID in workspaceOnly[RemoteWorkspaceIdentity(
                        resource: identity.resource,
                        workspaceID: identity.workspaceID
                    )] ?? [] {
                        counts[workspaceID, default: 0] += 1
                    }
                }
                // A pre-placement record has no coordinates. The initializer
                // has proven that the resource has one projection and one
                // remote view; the per-workspace count below preserves the
                // old rule that this inference is safe only for one placement.
                if placementCountByResource[identity.resource] == 1 {
                    for workspaceID in legacy[identity.resource] ?? [] {
                        counts[workspaceID, default: 0] += 1
                    }
                }
            }
            return counts.max { lhs, rhs in
                lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key.uuidString > rhs.key.uuidString
            }?.key
        }
    }

    /// Returns every current placement, with a nil view only for legacy
    /// providers that expose a workspace but no tab id. An explicit empty view
    /// array means the resource is detached and must not be invented in a
    /// workspace. Duplicate wire placements are ignored deterministically.
    private static func remotePlacements(of resource: SurfaceResource) -> [RemoteResourcePlacement] {
        if let views = resource.remoteViews {
            var seenTabIDs = Set<String>()
            return views.compactMap { view in
                guard !view.tabID.isEmpty, seenTabIDs.insert(view.tabID).inserted else { return nil }
                return RemoteResourcePlacement(resource: resource, workspace: view.workspace, view: view)
            }
        }
        guard let workspace = resource.remoteWorkspace else { return [] }
        return [RemoteResourcePlacement(resource: resource, workspace: workspace, view: nil)]
    }

    private static func uniqueResources(_ placements: [RemoteResourcePlacement]) -> [SurfaceResource] {
        var seen = Set<SurfaceResourceID>()
        return placements.compactMap { placement in
            seen.insert(placement.resource.id).inserted ? placement.resource : nil
        }
    }

    static func nodes(
        machines: [MachineSnapshot],
        pendingCreates: [MachineCreateOperation] = [],
        snapshot: SurfaceCatalogSnapshot,
        localWorkspaces: [CloudTreeLocalWorkspace],
        includeLocalMachine: Bool = CloudTreeNodeBuilder.includesLocalMachine
    ) -> [CloudTreeNode] {
        let projectionIndex = LocalProjectionIndex(snapshot: snapshot)
        var nodes: [CloudTreeNode] = []
        if includeLocalMachine, let local = snapshot.machines.first(where: { $0.id.isLocal }) {
            nodes.append(localMachineNode(
                info: local,
                snapshot: snapshot,
                localWorkspaces: localWorkspaces,
                projectionIndex: projectionIndex
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
                    projectionIndex: projectionIndex
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
                    projectionIndex: projectionIndex
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
    static func nodeID(terminalsPlaceholder machine: SurfaceMachineID) -> String {
        "machine:\(machine.rawValue)/terminals/placeholder"
    }
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

    /// The local workspace that shows a remote workspace: the one holding the most
    /// exact remote placements (at least one). A resource id alone is not enough
    /// because one terminal can have views in several remote workspaces.
    static func localWorkspaceShowing(
        remoteWorkspaceID: String,
        placements: [SurfaceResourcePlacement],
        snapshot: SurfaceCatalogSnapshot
    ) -> UUID? {
        LocalProjectionIndex(snapshot: snapshot).localWorkspaceShowing(
            remoteWorkspaceID: remoteWorkspaceID,
            placements: placements
        )
    }

    static func nodeID(resource: SurfaceResourceID) -> String { "resource:\(resource.rawValue)" }
    /// A pointer row: the same resource can sit under several workspaces and tabs (and the
    /// pool), so each row's identity carries its exact placement. Keeping the tab id in the
    /// key prevents expansion, selection, drag, and rename from collapsing onto one row.
    static func nodeID(resource: SurfaceResourceID, inRemoteWorkspace workspaceID: String) -> String {
        nodeID(resource: resource, inRemoteWorkspace: workspaceID, remoteTabID: nil)
    }

    static func nodeID(
        resource: SurfaceResourceID,
        inRemoteWorkspace workspaceID: String,
        remoteTabID: String?
    ) -> String {
        let tabSuffix = remoteTabID.map { "/tab:\($0)" } ?? ""
        return "machine:\(resource.machine.rawValue)/ws/\(workspaceID)/resource:\(resource.rawValue)\(tabSuffix)"
    }
    static func nodeID(browsersGroup machine: SurfaceMachineID) -> String { "machine:\(machine.rawValue)/browsers" }
    static func nodeID(portsGroup machine: SurfaceMachineID) -> String { "machine:\(machine.rawValue)/ports" }
    static func nodeID(placeholder machine: SurfaceMachineID) -> String { "machine:\(machine.rawValue)/placeholder" }

    // MARK: This Mac

    private static func localMachineNode(
        info: SurfaceMachineInfo,
        snapshot: SurfaceCatalogSnapshot,
        localWorkspaces: [CloudTreeLocalWorkspace],
        projectionIndex: LocalProjectionIndex
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
                children: projected.map {
                    terminalNode($0, snapshot: snapshot, projectionIndex: projectionIndex)
                },
                dragGroup: SurfaceResourceGroup(title: title, resources: (projected + projectedBrowsers).map(\.id))
            )
        }
        children.append(contentsOf: unplaced.map {
            terminalNode($0, snapshot: snapshot, projectionIndex: projectionIndex)
        })
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
                            isOpen: projectionIndex.isOpen(browser.id, remoteView: nil),
                            workspaceTitle: workspaceOf(browser.id).flatMap { titles[$0] },
                            remoteView: nil
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

    private static func cloudChildren(
        machine: SurfaceMachineID,
        info: SurfaceMachineInfo?,
        snapshot: SurfaceCatalogSnapshot,
        projectionIndex: LocalProjectionIndex
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
            // Workspaces stay first. Their child rows retain exact remote tab
            // identities, while the later Terminals group lists every process.
            children.append(workspacesGroupNode(
                machine: machine,
                info: info,
                resources: resources,
                snapshot: snapshot,
                projectionIndex: projectionIndex
            ))
        }
        // Ports: one row per listening port, titled as the URL a person would
        // paste (`http://<private-ip>:<port>`) when the machine has a private
        // address; the bare `:<port>` otherwise. Click opens it as a browser
        // pane; the row's menu copies the link.
        let portBrowsers = resources
            .filter { $0.id.isForwardedPort }
            .sorted {
                let left = ($0.id.forwardedPort ?? $0.port ?? 0, $0.id.key)
                let right = ($1.id.forwardedPort ?? $1.port ?? 0, $1.id.key)
                return left.0 != right.0 ? left.0 < right.0 : left.1 < right.1
            }
        if !portBrowsers.isEmpty {
            children.append(CloudTreeNode(
                id: nodeID(portsGroup: machine),
                kind: .portsGroup(machine: machine),
                children: portBrowsers.map {
                    CloudTreeNode(
                        id: nodeID(resource: $0.id),
                        kind: .port(
                            $0,
                            url: $0.url ?? portURL(
                                machine: machine,
                                info: info,
                                port: $0.id.forwardedPort ?? $0.port
                            ),
                            openIn: projectionIndex.localWorkspaceShowing(resource: $0.id)
                        )
                    )
                }
            ))
        }

        // Displays stay reachable while the session link reconnects.
        if !displays.isEmpty {
            children.append(CloudTreeNode(
                id: nodeID(displaysPool: machine),
                kind: .displaysPool(machine: machine, count: displays.count),
                children: displays.map {
                    CloudTreeNode(
                        id: nodeID(resource: $0.id),
                        kind: .display(
                            $0,
                            openIn: nil,
                            remoteView: $0.remoteViews?.count == 1 ? $0.remoteViews?.first : nil
                        )
                    )
                }
            ))
        }

        // The pool is a process index. It lists every terminal, including
        // terminals already placed in workspaces and detached terminals.
        if info.linkState == .connected || info.linkState == .notApplicable || !terminals.isEmpty {
            children.append(terminalsGroupNode(
                machine: machine,
                terminals: terminals,
                snapshot: snapshot,
                projectionIndex: projectionIndex
            ))
        }
        return children
    }

    /// The Workspaces group is a placement projection of the daemon graph. A
    /// resource can appear once for every exact tab view, while an empty workspace
    /// still gets a row from machine info. This is the sole tree construction path
    /// for workspace rows, so ordering and rename identity cannot diverge.
    private static func workspacesGroupNode(
        machine: SurfaceMachineID,
        info: SurfaceMachineInfo,
        resources: [SurfaceResource],
        snapshot: SurfaceCatalogSnapshot,
        projectionIndex: LocalProjectionIndex
    ) -> CloudTreeNode {
        let displays = resources.filter { $0.kind == .display }
        var byWorkspace: [String: RemoteWorkspaceRows] = [:]
        for workspace in info.remoteWorkspaces ?? [] {
            byWorkspace[workspace.id] = RemoteWorkspaceRows(workspace: workspace)
        }
        for resource in resources {
            for placement in remotePlacements(of: resource) {
                var rows = byWorkspace[placement.workspace.id] ?? RemoteWorkspaceRows(workspace: placement.workspace)
                switch resource.kind {
                case .terminal: rows.terminals.append(placement)
                case .browser: rows.browsers.append(placement)
                case .display: rows.displays.append(placement)
                }
                byWorkspace[placement.workspace.id] = rows
            }
        }
        let workspaces = byWorkspace.values.sorted { lhs, rhs in
            lhs.workspace.index != rhs.workspace.index ? lhs.workspace.index < rhs.workspace.index : lhs.workspace.id < rhs.workspace.id
        }
        let workspaceNodes = workspaces.map { rows in
            let workspace = rows.workspace
            let terminalPlacements = rows.terminals
            let browserPlacements = rows.browsers
            let displayPlacements = rows.displays
            let realPlacements = (terminalPlacements + browserPlacements + displayPlacements).map { placement in
                SurfaceResourcePlacement(
                    resource: placement.resource.id,
                    remoteView: placement.view,
                    remoteWorkspaceID: workspace.id
                )
            }
            let shownDisplayPlacements: [RemoteResourcePlacement] = displayPlacements.isEmpty
                ? displays.map { RemoteResourcePlacement(resource: $0, workspace: workspace, view: nil) }
                : displayPlacements
            let openInLocal = projectionIndex.localWorkspaceShowing(
                remoteWorkspaceID: workspace.id,
                placements: realPlacements
            )
            return CloudTreeNode(
                id: nodeID(workspace: workspace.id, machine: machine),
                kind: .workspace(
                    machine: machine,
                    workspace,
                    terminalCount: uniqueResources(terminalPlacements).count,
                    openIn: openInLocal
                ),
                children: terminalPlacements.map { placement in
                    terminalNode(
                        placement.resource,
                        snapshot: snapshot,
                        projectionIndex: projectionIndex,
                        id: nodeID(
                            resource: placement.resource.id,
                            inRemoteWorkspace: workspace.id,
                            remoteTabID: placement.view?.tabID
                        ),
                        remoteView: placement.view
                    )
                } + browserPlacements.map { placement in
                    let id = nodeID(
                        resource: placement.resource.id,
                        inRemoteWorkspace: workspace.id,
                        remoteTabID: placement.view?.tabID
                    )
                    if placement.resource.id.isForwardedPort {
                        return CloudTreeNode(
                            id: id,
                            kind: .port(
                                placement.resource,
                                url: placement.resource.url ?? portURL(
                                    machine: machine,
                                    info: info,
                                    port: placement.resource.id.forwardedPort ?? placement.resource.port
                                ),
                                openIn: openInLocal
                            )
                        )
                    }
                    return CloudTreeNode(
                        id: id,
                        kind: .browser(CloudTreeBrowserRow(
                            resource: placement.resource,
                            isOpen: projectionIndex.isOpen(placement.resource.id, remoteView: placement.view),
                            workspaceTitle: nil,
                            remoteView: placement.view
                        ))
                    )
                } + shownDisplayPlacements.map { placement in
                    CloudTreeNode(
                        id: nodeID(
                            resource: placement.resource.id,
                            inRemoteWorkspace: workspace.id,
                            remoteTabID: placement.view?.tabID
                        ),
                        kind: .display(
                            placement.resource,
                            openIn: openInLocal,
                            remoteView: placement.view
                        )
                    )
                },
                dragGroup: SurfaceResourceGroup(
                    title: workspace.name,
                    placements: realPlacements,
                    remoteWorkspaceID: workspace.id
                )
            )
        }
        let rows: [CloudTreeNode] = workspaceNodes.isEmpty
            ? [CloudTreeNode(
                id: nodeID(workspacesPlaceholder: machine),
                kind: .placeholder(machine: machine, CloudTreePlaceholder(
                    text: String(localized: "cloudTree.placeholder.noWorkspaces", defaultValue: "No workspaces yet"),
                    style: .dimmed
                ))
            )]
            : workspaceNodes
        return CloudTreeNode(
            id: nodeID(workspacesGroup: machine),
            kind: .workspacesGroup(machine: machine),
            children: rows
        )
    }

    /// Every terminal process on the machine. Workspace pointer rows show tab
    /// names; pool rows show the process title and the number of daemon views.
    private static func terminalsGroupNode(
        machine: SurfaceMachineID,
        terminals: [SurfaceResource],
        snapshot: SurfaceCatalogSnapshot,
        projectionIndex: LocalProjectionIndex
    ) -> CloudTreeNode {
        var rows = terminals.map {
            terminalNode(
                $0,
                snapshot: snapshot,
                projectionIndex: projectionIndex,
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

    private static func terminalNode(
        _ resource: SurfaceResource,
        snapshot: SurfaceCatalogSnapshot,
        projectionIndex: LocalProjectionIndex,
        id: String? = nil,
        viewBadge: Int? = nil,
        remoteView: SurfaceRemoteView? = nil
    ) -> CloudTreeNode {
        CloudTreeNode(
            id: id ?? nodeID(resource: resource.id),
            kind: .terminal(CloudTreeTerminalRow(
                resource: resource,
                isOpen: projectionIndex.isOpen(resource.id, remoteView: remoteView),
                viewBadge: viewBadge,
                remoteView: remoteView
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
