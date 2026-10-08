import CmuxCloud
import CmuxCore
import CmuxFoundation
import CmuxSurfaceCatalogModel
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
    struct CoderouterAccount: Equatable {
        let id: String
        let provider: CoderouterProvider
        let label: String?
        let state: String?
        /// Percent of the current rate-limit window still available; nil when
        /// the provider reports no window.
        var remainingPercent: Int? = nil
        /// The masked key CodeRouter reports for key and token accounts ("sk-ant-oat01-...JF1g").
        var identifier: String? = nil

        /// The label, else the type plus the key suffix `cr` prints ("Claude …JF1g").
        var title: String {
            if let label, !label.isEmpty { return label }
            guard let identifier, let suffix = identifier.split(separator: ".").last, !suffix.isEmpty, suffix.count < identifier.count else {
                return provider.title
            }
            return "\(provider.title) \u{2026}\(suffix)"
        }
    }
    // Box the payload once: machine/catalog snapshots otherwise enlarge every
    // case and every row-content copy by hundreds of bytes.
    indirect enum Kind: Equatable {
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
        /// "Displays" group under a cloud machine: one row per VNC screen it exposes.
        case displaysPool(machine: SurfaceMachineID, count: Int, canCreate: Bool = false)
        /// "Workspaces" group under a machine.
        case workspacesGroup(machine: SurfaceMachineID)
        /// A cmux-tui workspace on a cloud machine; its children are flat pointer rows
        /// into the machine's pools, one row per terminal, browser, or display placement.
        /// `terminalCount` counts every terminal placement in the workspace.
        /// `openIn`: the local workspace already showing this remote one (its open mark;
        /// clicking jumps there), else nil.
        case workspace(machine: SurfaceMachineID, SurfaceRemoteWorkspace, terminalCount: Int, hiddenTabCount: Int, openIn: UUID?)
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
        case resourcesPool(machine: SurfaceMachineID, count: Int)
        case resource(machine: SurfaceMachineID, row: CloudTreeMachineResourceRow)
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
        /// Another Mac on the account (one tagged app instance), with its presence.
        case device(CloudTreeDeviceRow)
        /// The "Devices" section header when devices share the tree with the fleet.
        case devicesSection(CloudTreeDevicesSection)
        /// The team's CodeRouter section: its account count and refresh icon.
        case coderouterSection(count: Int, refresh: CloudTreeSectionRefresh)
        /// One account type (Codex, Claude, OpenCode); its children are that
        /// type's New Account row and accounts.
        case coderouterProviderGroup(CoderouterProvider, count: Int)
        case coderouterAccount(CoderouterAccount)
        /// The collapsible Cloud Machines section header. `canCreateMachine` shows its
        /// hover "+" (New Machine, Cmd-Y), false while Cloud Machines is off and the
        /// header stands alone; `usage` is the plan's count (nil until it loads), `refresh` its refresh icon.
        case cloudMachinesSection(canCreateMachine: Bool, usage: CloudMachinesUsage? = nil, refresh: CloudTreeSectionRefresh? = nil)
        case createAction(CloudTreeCreateAction)
        /// My Devices guidance and independent discovery actions, also shown with peers.
        case devicesEmpty(CloudTreeDevicesSection)
        /// The tab row under a Cloud machine's workspaces (Ports, Terminals,
        /// Resources); its children are the open tab's rows. Display only, see
        /// `CloudTreeMachineDetailLayout`.
        case machineDetailTabs(CloudTreeMachineDetailTabs)
        /// The gap after a Cloud machine's last row, before the next machine.
        case machineEndSpacer(machine: SurfaceMachineID)
        /// Port discovery is eager for expanded machines in the viewport; an explicit
        /// Ports disclosure still refreshes its machine and collapsed rows stay lazy.
        var refreshesOnExpansion: Bool { switch self { case .portsGroup, .displaysPool: true; default: false } }
        /// The identity glyph a top-level section header carries once for all of
        /// its rows, so the machine and device rows under it show no repeated icon.
        var sectionHeaderSymbol: String? {
            switch self {
            case .cloudMachinesSection: "cloud"
            case .devicesSection: "desktopcomputer"
            case .coderouterSection: "chevron.left.forwardslash.chevron.right"
            default: nil
            }
        }
    }
    let id: String
    private(set) var kind: Kind
    var children: [CloudTreeNode]
    var isPinned = false
    var resourceSection: CloudTreeMachineResourceSection?
    /// For a machine's tab row: every group it stands for (Ports, Terminals,
    /// Resources), kept so the row can be rebuilt when another tab opens.
    var detailPools: [CloudTreeNode] = []
    /// For workspace rows: everything the workspace holds, in the order it opens.
    private var explicitDragGroup: SurfaceResourceGroup?
    init(id: String, kind: Kind, children: [CloudTreeNode] = [], dragGroup: SurfaceResourceGroup? = nil, isPinned: Bool = false) {
        self.id = id
        self.kind = kind
        self.children = children
        self.explicitDragGroup = dragGroup
        self.isPinned = isPinned
    }
    var isExpandable: Bool { !children.isEmpty }
    var contentSnapshot: CloudTreeNodeContentSnapshot {
        .init(
            id: id,
            kind: kind,
            explicitDragGroup: explicitDragGroup,
            isPinned: isPinned,
            hasUnreadAttention: hasUnreadAttention,
            resourceSection: resourceSection
        )
    }
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
        case .resourcesPool: return "resourcesPool"
        case .resource: return "resource"
        case .port: return "port"
        case .placeholder: return "placeholder"
        case .device: return "device"
        case .devicesSection: return "devicesSection"
        case .coderouterSection: return "coderouterSection"
        case .coderouterProviderGroup: return "coderouterProviderGroup"
        case .coderouterAccount: return "coderouterAccount"
        case .cloudMachinesSection: return "cloudMachinesSection"
        case .createAction: return "createAction"
        case .devicesEmpty: return "devicesEmpty"
        case .machineDetailTabs: return "machineDetailTabs"
        case .machineEndSpacer: return "machineEndSpacer"
        }
    }
    /// Copies the values of an equal-structure rebuild into this node (NSOutlineView keeps
    /// the object it was handed; updating it in place keeps rows, expansion and the
    /// selection untouched). Children are adopted pairwise — callers guarantee the
    /// structure signature matched first.
    func adopt(from other: CloudTreeNode) {
        kind = other.kind
        isPinned = other.isPinned
        explicitDragGroup = other.explicitDragGroup
        resourceSection = other.resourceSection
        detailPools = other.detailPools
        for (child, replacement) in zip(children, other.children) {
            child.adopt(from: replacement)
        }
    }
    /// Replaces this node's values and children with another node's, keeping
    /// this object. Used when a display-only regroup rebuilds a row the
    /// outline already holds, so the outline never keeps a stale copy.
    func take(from other: CloudTreeNode) {
        kind = other.kind
        children = other.children
        isPinned = other.isPinned
        explicitDragGroup = other.explicitDragGroup
        resourceSection = other.resourceSection
        detailPools = other.detailPools
    }
    var machine: SurfaceMachineID {
        switch kind {
        case .machine(let snapshot, _): return .cloud(snapshot.id)
        // No machine exists yet; the id keeps the row addressable (drag
        // registries, debug logs) without colliding with a real machine.
        case .pendingMachine(let operation): return .cloud("pending:\(operation.id.uuidString)")
        case .localMachine: return .local
        case .workspacesGroup(let machine), .browsersGroup(let machine), .portsGroup(let machine), .resourcesPool(let machine, _):
            return machine
        case .terminalsPool(let machine, _), .displaysPool(let machine, _, _):
            return machine
        case .resource(let machine, _):
            return machine
        case .workspace(let machine, _, _, _, _), .placeholder(let machine, _):
            return machine
        case .localWorkspace: return .local
        case .terminal(let row): return row.resource.machine
        case .display(let resource, _, _): return resource.machine
        case .port(let resource, _, _): return resource.machine
        case .browser(let row): return row.resource.machine
        case .device(let row): return row.machine
        case .devicesSection, .devicesEmpty: return .cloud("devices-section")
        case .coderouterSection, .coderouterProviderGroup, .coderouterAccount: return .cloud("coderouter-section")
        case .cloudMachinesSection: return .cloud("cloud-machines-section")
        case .createAction(let action): return action.machine
        case .machineDetailTabs(let tabs): return tabs.machine
        case .machineEndSpacer(let machine): return machine
        }
    }
    var isMachineRow: Bool {
        switch kind {
        case .machine, .localMachine, .pendingMachine, .device: return true
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
        case .displaysPool: return String(localized: "cloudTree.group.displays", defaultValue: "Displays")
        case .workspacesGroup: return String(localized: "cloudTree.group.workspaces", defaultValue: "Workspaces")
        case .workspace(_, let workspace, _, _, _): return workspace.name
        case .localWorkspace(let row): return row.title
        case .terminal(let row): return row.displayTitle
        case .display(let resource, _, let remoteView):
            return CloudTreeResourceName(resource: resource, remoteView: remoteView).displayName
        case .browsersGroup: return String(localized: "cloudTree.group.browsers", defaultValue: "Browsers")
        case .browser(let row): return CloudTreeResourceName(resource: row.resource, remoteView: row.remoteView).browserName
        case .portsGroup: return String(localized: "cloudTree.group.ports", defaultValue: "Ports")
        case .resourcesPool: return String(localized: "cloudTree.group.resources", defaultValue: "Resources")
        case .resource(_, let row): return row.title
        case .port(let resource, _, _):
            return CloudTreePortPresentation(resource: resource).title
        case .placeholder(_, let placeholder): return placeholder.text
        case .device(let row): return row.searchableTitle
        case .devicesSection: return String(localized: "cloudTree.group.devices", defaultValue: "My Devices")
        case .coderouterSection: return String(localized: "cloudTree.group.coderouter", defaultValue: "Coderouter")
        case .coderouterProviderGroup(let provider, _): return provider.title
        case .coderouterAccount(let account): return account.title
        case .cloudMachinesSection: return String(localized: "cloudTree.group.cloudMachines", defaultValue: "Cloud Machines")
        case .createAction(let action): return action.title
        case .machineDetailTabs, .machineEndSpacer: return ""
        case .devicesEmpty(let section):
            return section.count == 0
                ? String(localized: "devices.empty.title", defaultValue: "No other devices yet")
                : String(localized: "devices.manage", defaultValue: "Manage My Devices")
        }
    }

    /// What dragging this row into the main view projects: a single resource wrapped as a
    /// one-element group, or a workspace's whole collection (terminals, then browsers).
    /// Machine rows reorder only inside the sidebar and never project panes.
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
        // No `.browser` branch: `isDragSource` admits only terminals and
        // displays, and `CloudTreeDragRegistration` is the only reader of a leaf
        // row's group, so a browser row never gets here. Granting browsers a
        // projection capability is a separate decision, not a naming fix.
        if case .display(let resource, _, let view) = kind,
           let view {
            // The group's title names the local workspace the drag produces, so
            // it has to be the name the row is showing. Reading `resource.title`
            // raw dropped a rename on the way out: a display renamed to "Docs"
            // landed under its bare resource title instead. An empty title was
            // never nameless — `localWorkspaceTitle(hostName:)` falls back to
            // the machine — it just lost the name the user typed.
            let name = CloudTreeResourceName(resource: resource, remoteView: view)
            return SurfaceResourceGroup(
                title: name.displayName,
                placements: [SurfaceResourcePlacement(resource: resource.id, remoteView: view)],
                remoteWorkspaceID: view.workspace.id
            )
        }
        return dragResource.map { SurfaceResourceGroup(single: $0) }
    }
    /// Whether a native drag may export a pane projection. Remote workspace rows
    /// export their complete placement group; local workspace rows remain
    /// reorder-only because their group refers to live panes that cannot be
    /// materialized without moving them out of the source workspace.
    var isDragSource: Bool {
        switch kind {
        case .terminal, .display: return true
        case .workspace(let machine, _, _, _, _) where !machine.isLocal:
            guard let group = dragGroup, !group.isEmpty else { return false }
            return group.resources.allSatisfy { !$0.machine.isLocal }
        default: return false
        }
    }

    /// The single resource a leaf row stands for; nil for workspace rows and headers.
    var dragResource: SurfaceResource? {
        switch kind {
        case .terminal(let row): return row.resource
        case .browser(let row): return row.resource
        case .display(let resource, _, _), .port(let resource, _, _): return resource
        case .machine, .pendingMachine, .localMachine, .terminalsPool, .displaysPool, .workspacesGroup, .workspace, .localWorkspace, .browsersGroup, .portsGroup, .resourcesPool, .resource, .placeholder, .device, .devicesSection, .devicesEmpty, .cloudMachinesSection, .coderouterSection, .coderouterProviderGroup, .coderouterAccount, .createAction,
             .machineDetailTabs, .machineEndSpacer:
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
    var directoryIsCurrent = true
    var machineDisplayName: String? = nil
    /// Unread remote notification, scoped to this Mac's read state.
    var hasUnreadNotification: Bool = false
    /// The exact daemon tab represented by a workspace pointer row. Pool rows
    /// leave this nil because one terminal may have several placement names.
    var remoteView: SurfaceRemoteView? = nil
    var hiddenTabCount: Int = 0
    /// The workspaces showing this terminal, for a machine's Terminals tab;
    /// nil elsewhere and for a terminal in no workspace.
    var workspaceLabel: String? = nil

    /// Placement names override the shared process title only in their own workspace.
    var displayTitle: String {
        if let name = remoteView?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return resource.machine.isLocal ? resource.title : (remoteView == nil ? resource.cloudPoolDisplayTitle : resource.cloudProcessDisplayTitle)
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
    /// Legacy payload retained for source compatibility; flat projections always set zero.
    var hiddenTabCount: Int = 0
}

/// A local workspace, in sidebar order, for grouping this Mac's terminals.
struct CloudTreeLocalWorkspace: Equatable {
    let id: UUID
    let title: String
    let isSelected: Bool
}

/// Pure assembly of outline nodes from the fleet rows and the catalog snapshot.
/// Order: This Mac (local workspaces → terminals; Browsers) first, then every
/// cloud machine, with Workspaces, Ports, Displays, Terminals, and Resources in order.
/// Workspace children preserve exact daemon
/// tab placement identities. A machine without a connected link keeps cached
/// pool rows beside its status placeholder.
enum CloudTreeNodeBuilder {
    /// Whether the tree shows this Mac's own terminals and browsers. Off for now —
    /// the Machines panel is the cloud fleet; this Mac's surfaces already live in the
    /// sidebar — and the gate stays so the mixed tree remains one flip away.
    nonisolated(unsafe) static var includesLocalMachine = false

    /// A row is a placement, not only a resource. The same terminal can occur
    /// in two tabs of one workspace, and those tabs can have different names.
    struct RemoteResourcePlacement {
        let resource: SurfaceResource
        let workspace: SurfaceRemoteWorkspace
        let view: SurfaceRemoteView?
    }

    struct RemoteWorkspaceRows {
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
    struct LocalProjectionIndex {
        private var exact: [RemotePlacementIdentity: [UUID]] = [:]
        /// A projection from a provider that does not model tabs. This is only
        /// used when the current resource also has no view metadata, so it
        /// cannot claim an arbitrary tab in a multi-view resource.
        private var workspaceOnly: [RemoteWorkspaceIdentity: [UUID]] = [:]
        private var legacy: [SurfaceResourceID: [UUID]] = [:]
        private var openResources: Set<SurfaceResourceID> = []
        private var openPlacements: Set<RemotePlacementIdentity> = []
        private var workspaceCountsByResource: [SurfaceResourceID: [UUID: Int]] = [:]
        /// Terminals whose machine holds a notification this Mac has not read.
        private var unreadTerminals: Set<SurfaceResourceID> = []

        init(snapshot: SurfaceCatalogSnapshot, unreadTerminalIDs: [String: Set<String>]) {
            self.init(snapshot: snapshot)
            for (machineID, terminalIDs) in unreadTerminalIDs {
                // Hub keys are machine raw values: a Cloud machine id or a
                // device's `device:` id.
                let machine = SurfaceMachineID(rawValue: machineID)
                for terminalID in terminalIDs {
                    unreadTerminals.insert(SurfaceResourceID(machine: machine, kind: .terminal, key: terminalID))
                }
            }
        }

        func hasUnreadNotification(_ id: SurfaceResourceID) -> Bool {
            unreadTerminals.contains(id)
        }

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
                    if CloudTreeNodeBuilder.hasCloudDisplayMembershipProjection(projection, snapshot: snapshot, workspaceID: remoteWorkspaceID) {
                        workspaceOnly[RemoteWorkspaceIdentity(resource: projection.resource, workspaceID: remoteWorkspaceID), default: []].append(projection.workspaceID)
                    } else if let remoteTabID = projection.remoteTabID, !remoteTabID.isEmpty {
                        let identity = RemotePlacementIdentity(
                            resource: projection.resource,
                            workspaceID: remoteWorkspaceID,
                            tabID: remoteTabID
                        )
                        openPlacements.insert(identity)
                        exact[identity, default: []].append(projection.workspaceID)
                    } else if let views = resourceByID[projection.resource]?.remoteViews,
                              !views.allSatisfy(\.isCloudDisplayMembershipView) {
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
    /// True when `nodes(machines:snapshot:localWorkspaces:)` would produce no
    /// rows. The panel swaps the outline for its empty state on this; it must
    /// mirror `nodes` exactly (local catalog entries only count while
    /// `includesLocalMachine` is on, device entries only count for a source
    /// that lists them), or a fresh account renders a blank outline instead of
    /// the empty state.
    static func isEmpty(
        machines: [MachineSnapshot],
        pendingCreates: [MachineCreateOperation] = [],
        snapshot: SurfaceCatalogSnapshot,
        includeLocalMachine: Bool = CloudTreeNodeBuilder.includesLocalMachine,
        source: CloudTreeMachineSource = .cloud
    ) -> Bool {
        if source.groupsDevicesUnderSection { return false }
        if source.includesCloudMachines {
            guard machines.isEmpty, pendingCreates.isEmpty else { return false }
            if snapshot.machines.contains(where: { (includeLocalMachine && $0.id.isLocal) || $0.id.cloudMachineID != nil }) {
                return false
            }
        }
        if source.includesDevices, snapshot.machines.contains(where: { $0.id.isDevice }) {
            return false
        }
        return true
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

    static func localMachineNode(
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
        return CmuxInternalHostnames().directPortURL(privateAddress: address, port: port)
    }

    static func cloudChildren(
        machine: SurfaceMachineID,
        machineSnapshot: MachineSnapshot?,
        info: SurfaceMachineInfo?,
        snapshot: SurfaceCatalogSnapshot,
        projectionIndex: LocalProjectionIndex,
        resourceNodeBuilder: CloudTreeMachineResourceNodeBuilder,
        now: Date,
        machineResources: [SurfaceResource]? = nil,
        showsCloudVPNWarning: Bool = false
    ) -> [CloudTreeNode] {
        var children: [CloudTreeNode] = []
        let resources = machineResources ?? snapshot.resources(on: machine)
        let terminals = resources.filter { $0.kind == .terminal }
        let displays = info.map { CloudMachineSurfacePresentation.displays(resources: resources, info: $0) } ?? []
        if let info {
            switch info.linkState {
            case .asleep:
                children.append(placeholder(machine, text: String(localized: "cloudTree.placeholder.asleep", defaultValue: "Asleep — open to wake"), style: .dimmed, opensMachine: true))
            case .connecting:
                children.append(placeholder(machine, text: String(localized: "cloudTree.placeholder.connecting", defaultValue: "Connecting…"), style: .connecting))
                // A create receipt is already a stable workspace identity even
                // while the machine link is connecting. Keep that one pending
                // row visible so the Cloud tree and local navigator converge at
                // the same admission boundary.
                if snapshot.pendingWorkspaceCreations?[machine]?.isEmpty == false {
                    children.append(workspacesGroupNode(
                        machine: machine,
                        info: info,
                        resources: resources,
                        snapshot: snapshot,
                        projectionIndex: projectionIndex
                    ))
                }
            case .error:
                children.append(placeholder(machine, text: info.linkFailureMessage, style: .error))
            case .unavailable:
                children.append(placeholder(machine, text: info.linkFailureMessage, style: .dimmed))
            case .offline:
                children.append(placeholder(machine, text: String(localized: "cloudTree.placeholder.deviceOffline", defaultValue: "Offline — its workspaces return when it does"), style: .dimmed))
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
            // pane; the row's menu copies the link. Another Mac exposes no
            // cmux-managed ports or desktop, so device rows skip both groups.
            if !machine.isDevice {
                let portBrowsers = resources
                    .filter { $0.id.isForwardedPort }
                    .sorted {
                        let left = ($0.id.forwardedPort ?? $0.port ?? 0, $0.id.key)
                        let right = ($1.id.forwardedPort ?? $1.port ?? 0, $1.id.key)
                        return left.0 != right.0 ? left.0 < right.0 : left.1 < right.1
                    }
                children.append(CloudTreeNode(
                    id: nodeID(portsGroup: machine),
                    kind: .portsGroup(machine: machine),
                    children: Self.portChildren(
                        machine: machine,
                        info: info,
                        resources: portBrowsers,
                        projectionIndex: projectionIndex,
                        showsCloudVPNWarning: showsCloudVPNWarning
                    )
                ))
            }
            // Cloud machines expose Displays as a machine-level category, just like
            // Ports and Terminals. Personal Macs do not publish Cloud desktop/VNC
            // resources, so omit the category entirely instead of rendering an
            // empty "No displays available" row on every connected device.
            if !machine.isDevice && (info.linkState == .connected || info.linkState == .notApplicable || !displays.isEmpty) {
                children.append(CloudTreeNode(
                    id: nodeID(displaysPool: machine),
                    kind: .displaysPool(machine: machine, count: displays.count, canCreate: snapshot.displayCreationMachines?.contains(machine) == true),
                    children: (displays.isEmpty
                        ? (snapshot.pendingDisplayCreations?.contains(machine) == true ? [] : [CloudMachineSurfacePresentation.emptyDisplays(info: info)])
                        : displays.map {
                            CloudTreeNode(
                                id: nodeID(resource: $0.id),
                                kind: .display(
                                    $0,
                                    openIn: nil,
                                    remoteView: $0.remoteViews?.count == 1 ? $0.remoteViews?.first : nil
                                )
                            )
                        }) + pendingDisplayRows(machine: machine, snapshot: snapshot)
                ))
            }
            if info.linkState == .connecting || info.linkState == .connected || info.linkState == .notApplicable || !terminals.isEmpty {
                children.append(terminalsGroupNode(
                    machine: machine,
                    terminals: terminals,
                    snapshot: snapshot,
                    projectionIndex: projectionIndex
                ))
            }
        } else {
            children.append(placeholder(machine, text: String(localized: "cloudTree.placeholder.connecting", defaultValue: "Connecting…"), style: .connecting))
        }
        // VM telemetry owns its availability and freshness independently of
        // the terminal link and surface catalog. Another Mac publishes no fleet
        // snapshot, so device rows carry no Resources group.
        if let machineSnapshot {
            children.append(resourceNodeBuilder.groupNode(machine: machine, snapshot: machineSnapshot, now: now))
        } else if info?.linkState == .connecting {
            // Keep the stable Resources control while a machine reconnects.
            // Telemetry is unavailable until the VM snapshot arrives, so the
            // group is intentionally empty and does not imply stale readings.
            let placeholder = MachineSnapshot(
                id: machine.rawValue, provider: "", image: "", isDesktop: false, activity: .pending)
            children.append(resourceNodeBuilder.groupNode(machine: machine, snapshot: placeholder, now: now))
        }
        return children
    }
    /// Builds every nonempty Cloud workspace from its actual layout members.
    /// Empty daemon records remain available to lookup and persistence.
    private static func workspacesGroupNode(
        machine: SurfaceMachineID,
        info: SurfaceMachineInfo,
        resources: [SurfaceResource],
        snapshot: SurfaceCatalogSnapshot,
        projectionIndex: LocalProjectionIndex
    ) -> CloudTreeNode {
        var byWorkspace: [String: RemoteWorkspaceRows] = [:]
        for workspace in info.remoteWorkspaces ?? [] {
            byWorkspace[workspace.id] = RemoteWorkspaceRows(workspace: workspace)
        }
        // One list for both passes: the membership copies of member displays
        // are what tell the local-pane pass a display is already listed. With
        // the pool resources alone, a New Display pane showed as two rows.
        let workspaceResources = snapshot.cloudWorkspaceResources(on: machine)
        for resource in workspaceResources {
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
        for member in SurfaceProjection.localWorkspaceMembers(resources: workspaceResources, projections: snapshot.projections) {
            guard var rows = byWorkspace[member.workspaceID] else { continue }
            let placement = RemoteResourcePlacement(resource: member.resource, workspace: rows.workspace, view: nil)
            if member.resource.kind == .browser { rows.browsers.append(placement) }
            else { rows.displays.append(placement) }
            byWorkspace[member.workspaceID] = rows
        }
        let workspaces = byWorkspace.values.filter { !$0.terminals.isEmpty || !$0.browsers.isEmpty || !$0.displays.isEmpty || snapshot.pendingWorkspaceCreations?[machine]?[$0.workspace.id] != nil }.sorted { lhs, rhs in
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
            let openInLocal = projectionIndex.localWorkspaceShowing(
                remoteWorkspaceID: workspace.id,
                placements: realPlacements
            ) ?? snapshot.pendingWorkspaceCreations?[machine]?[workspace.id]
            let layout = layoutRows(
                placements: terminalPlacements + browserPlacements + displayPlacements,
                workspace: workspace,
                machine: machine,
                info: info,
                snapshot: snapshot,
                projectionIndex: projectionIndex,
                openInLocal: openInLocal
            )
            // Open and drag use the same actual placements in the rows' order.
            let orderedRealPlacements = layout.placements.map { placement in
                SurfaceResourcePlacement(
                    resource: placement.resource.id,
                    remoteView: placement.view,
                    remoteWorkspaceID: workspace.id
                )
            }
            return CloudTreeNode(
                id: nodeID(workspace: workspace.id, machine: machine),
                kind: .workspace(
                    machine: machine,
                    workspace,
                    terminalCount: layout.terminalCount,
                    hiddenTabCount: 0,
                    openIn: openInLocal
                ),
                children: layout.rows,
                dragGroup: SurfaceResourceGroup(
                    title: workspace.name,
                    placements: orderedRealPlacements,
                    remoteWorkspaceID: workspace.id, representsWorkspace: true
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

    private struct WorkspaceLayoutRows {
        var rows: [CloudTreeNode] = []
        /// Every placement in row order. The workspace's open/drag group follows this
        /// order so opening a workspace lays out the same resources the tree lists.
        var placements: [RemoteResourcePlacement] = []
        /// Every terminal placement represented by a leaf row.
        var terminalCount = 0
    }

    /// A workspace's rows, ordered by its layout, with every placement as a leaf.
    /// Pane membership determines ordering only; it never creates a nested row.
    private static func layoutRows(
        placements: [RemoteResourcePlacement],
        workspace: SurfaceRemoteWorkspace,
        machine: SurfaceMachineID,
        info: SurfaceMachineInfo,
        snapshot: SurfaceCatalogSnapshot,
        projectionIndex: LocalProjectionIndex,
        openInLocal: UUID?
    ) -> WorkspaceLayoutRows {
        let layout = RemoteWorkspaceLayout(placements: placements.map { placement in
            RemoteWorkspacePlacement(
                screenID: placement.view?.screenID,
                paneID: placement.view?.paneID,
                screenIndex: placement.view?.screenIndex,
                paneIndex: placement.view?.paneIndex,
                tabIndex: placement.view?.index,
                focused: placement.view?.focused == true,
                kindOrder: placement.resource.kind == .terminal ? 0 : (placement.resource.kind == .browser ? 1 : 2)
            )
        })

        var result = WorkspaceLayoutRows()
        func append(_ placement: RemoteResourcePlacement) {
            result.rows.append(placementNode(
                placement, workspace: workspace, machine: machine, info: info, snapshot: snapshot,
                projectionIndex: projectionIndex, openInLocal: openInLocal
            ))
            result.placements.append(placement)
            if placement.resource.kind == .terminal { result.terminalCount += 1 }
        }
        for index in layout.flatPlacementIndices {
            append(placements[index])
        }
        return result
    }

    /// One flat pointer row for a placement, of the resource's kind.
    private static func placementNode(
        _ placement: RemoteResourcePlacement,
        workspace: SurfaceRemoteWorkspace,
        machine: SurfaceMachineID,
        info: SurfaceMachineInfo,
        snapshot: SurfaceCatalogSnapshot,
        projectionIndex: LocalProjectionIndex,
        openInLocal: UUID?
    ) -> CloudTreeNode {
        let id = nodeID(
            resource: placement.resource.id,
            inRemoteWorkspace: workspace.id,
            remoteTabID: placement.view?.tabID
        )
        switch placement.resource.kind {
        case .terminal:
            return terminalNode(
                placement.resource,
                snapshot: snapshot,
                projectionIndex: projectionIndex,
                id: id,
                remoteView: placement.view
            )
        case .browser:
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
        case .display:
            return CloudTreeNode(
                id: id,
                kind: .display(
                    placement.resource,
                    openIn: openInLocal,
                    remoteView: placement.view
                )
            )
        }
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
        remoteView: SurfaceRemoteView? = nil,
        hiddenTabCount: Int = 0
    ) -> CloudTreeNode {
        CloudTreeNode(
            id: id ?? nodeID(resource: resource.id),
            kind: .terminal(CloudTreeTerminalRow(
                resource: resource,
                isOpen: projectionIndex.isOpen(resource.id, remoteView: remoteView),
                viewBadge: viewBadge,
                directoryIsCurrent: !snapshot.staleMachineIDs.contains(resource.machine),
                machineDisplayName: snapshot.machines.first { $0.id == resource.machine }?.name,
                hasUnreadNotification: projectionIndex.hasUnreadNotification(resource.id),
                remoteView: remoteView,
                hiddenTabCount: hiddenTabCount
            ))
        )
    }

    /// The optimistic row for a guest display creation still in flight.
    private static func pendingDisplayRows(machine: SurfaceMachineID, snapshot: SurfaceCatalogSnapshot) -> [CloudTreeNode] {
        guard snapshot.pendingDisplayCreations?.contains(machine) == true else { return [] }
        return [CloudTreeNode(
            id: "\(nodeID(displaysPool: machine))/pending-display",
            kind: .placeholder(machine: machine, CloudTreePlaceholder(
                text: String(localized: "cloudTree.displays.starting", defaultValue: "Starting display…"),
                style: .connecting,
                opensMachine: false
            ))
        )]
    }

    private static func placeholder(
        _ machine: SurfaceMachineID,
        text: String,
        style: CloudTreePlaceholder.Style,
        opensMachine: Bool = false
    ) -> CloudTreeNode {
        CloudTreeNode(
            id: nodeID(placeholder: machine),
            kind: .placeholder(machine: machine, CloudTreePlaceholder(text: text, style: style, opensMachine: opensMachine))
        )
    }

}
