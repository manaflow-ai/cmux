import Foundation

/// One resource in a group, with the immutable daemon placement that produced the
/// row. A terminal id is not enough when one terminal is shown by several tabs.
/// The tab id is an opaque routing key; the current catalog resolves it to fresh
/// metadata immediately before materialization.
struct SurfaceResourcePlacement: Hashable, Codable, Sendable {
    let resource: SurfaceResourceID
    let remoteWorkspaceID: String?
    let remoteTabID: String?

    init(
        resource: SurfaceResourceID,
        remoteView: SurfaceRemoteView? = nil,
        remoteWorkspaceID: String? = nil,
        remoteTabID: String? = nil
    ) {
        self.resource = resource
        self.remoteWorkspaceID = remoteView?.workspace.id ?? remoteWorkspaceID
        self.remoteTabID = remoteView?.tabID ?? remoteTabID
    }
}

/// A collection of resources that travels as one drag or one "open all": a cmux-tui
/// workspace on a machine, or a local workspace (the panes it projects). The canonical
/// payload is typed placements. `resources` and the group workspace id remain as derived
/// compatibility views for older callers and persisted drag records.
struct SurfaceResourceGroup: Hashable, Codable, Sendable {
    let title: String
    let placements: [SurfaceResourcePlacement]
    /// A common placement used by legacy callers that have no per-member tab id.
    let remoteWorkspaceID: String?

    var resources: [SurfaceResourceID] { placements.map(\.resource) }
    var isEmpty: Bool { placements.isEmpty }

    func withRemoteWorkspaceID(_ id: String?) -> Self {
        SurfaceResourceGroup(title: title, placements: placements, remoteWorkspaceID: id ?? remoteWorkspaceID)
    }

    init(title: String, resources: [SurfaceResourceID], remoteWorkspaceID: String? = nil) {
        self.init(
            title: title,
            placements: resources.map {
                SurfaceResourcePlacement(resource: $0, remoteWorkspaceID: remoteWorkspaceID)
            },
            remoteWorkspaceID: remoteWorkspaceID
        )
    }

    init(
        title: String,
        placements: [SurfaceResourcePlacement],
        remoteWorkspaceID: String? = nil
    ) {
        self.title = title
        self.placements = placements
        self.remoteWorkspaceID = remoteWorkspaceID
    }

    init(single resource: SurfaceResource) {
        let view = resource.remoteViews?.count == 1 ? resource.remoteViews?.first : nil
        self.init(title: resource.title, placements: [SurfaceResourcePlacement(resource: resource.id, remoteView: view)])
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case resources
        case placements
        case remoteWorkspaceID
    }

    /// Decode both the placement-aware format and the original id-only format.
    /// Old records are deliberately marked only with their common workspace; if
    /// that workspace has several views, opening fails with an ambiguity error.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        let decodedRemoteWorkspaceID = try container.decodeIfPresent(String.self, forKey: .remoteWorkspaceID)
        remoteWorkspaceID = decodedRemoteWorkspaceID
        if let decoded = try container.decodeIfPresent([SurfaceResourcePlacement].self, forKey: .placements) {
            placements = decoded
        } else {
            let ids = try container.decodeIfPresent([SurfaceResourceID].self, forKey: .resources) ?? []
            placements = ids.map {
                SurfaceResourcePlacement(resource: $0, remoteWorkspaceID: decodedRemoteWorkspaceID)
            }
        }
    }

    /// Emit both fields for one migration window. Older clients read `resources`;
    /// newer clients retain exact tab ids from `placements`.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(resources, forKey: .resources)
        try container.encode(placements, forKey: .placements)
        try container.encodeIfPresent(remoteWorkspaceID, forKey: .remoteWorkspaceID)
    }
}

extension SurfaceCatalog {
    /// Builds the one canonical group for a daemon workspace. A resource is
    /// repeated once for every tab placement, so opening a workspace cannot
    /// collapse two tabs that point at the same terminal. The catalog snapshot
    /// is already ordered by daemon workspace and tab order; the kind buckets
    /// preserve the existing UI contract of terminals, browsers, then displays.
    func remoteWorkspaceGroup(
        machine: SurfaceMachineID,
        workspaceID: String
    ) throws -> SurfaceResourceGroup {
        let machineSnapshot = snapshot
        let machineInfo = machineSnapshot.machines.first { $0.id == machine }
        var workspace = machineInfo?.remoteWorkspaces?.first { $0.id == workspaceID }
        let resources = machineSnapshot.resources(on: machine)

        let orderedKinds: [SurfaceResourceKind] = [.terminal, .browser, .display]
        var placements: [SurfaceResourcePlacement] = []
        for kind in orderedKinds {
            for resource in resources where resource.kind == kind {
                if let views = resource.remoteViews {
                    for view in views where view.workspace.id == workspaceID {
                        workspace = workspace ?? view.workspace
                        placements.append(
                            SurfaceResourcePlacement(resource: resource.id, remoteView: view)
                        )
                    }
                } else if let resourceWorkspace = resource.remoteWorkspace,
                          resourceWorkspace.id == workspaceID {
                    workspace = workspace ?? resourceWorkspace
                    placements.append(
                        SurfaceResourcePlacement(
                            resource: resource.id,
                            remoteWorkspaceID: workspaceID
                        )
                    )
                }
            }
        }

        guard let workspace else {
            throw SurfaceCatalogError.destinationNotFound(
                "workspace \(workspaceID) on \(machine.rawValue)"
            )
        }
        guard !placements.isEmpty else {
            throw SurfaceCatalogError.destinationNotFound(
                "workspace \(workspaceID) on \(machine.rawValue) has no projectable resources"
            )
        }
        return SurfaceResourceGroup(
            title: workspace.name,
            placements: placements,
            remoteWorkspaceID: workspaceID
        )
    }

    /// Finds the pane hosting a panel, so the rest of a group can join it as tabs.
    typealias PaneLookup = @MainActor (_ panelID: UUID, _ workspaceID: UUID) -> String?

    /// Projects a group: the first resource lands exactly at `destination` (never reusing a
    /// pane elsewhere), every following one becomes a tab in the pane the first one created,
    /// so a dropped workspace arrives as one pane with its terminals and browsers as tabs.
    /// Resources the catalog does not know (or that fail to materialize) are skipped; only
    /// the first pane takes focus. Throws only when nothing could be projected.
    @discardableResult
    func projectGroup(
        _ ids: [SurfaceResourceID],
        into destination: SurfaceDestination,
        focus: Bool,
        remoteWorkspaceID: String? = nil,
        paneLookup: PaneLookup = { panelID, workspaceID in SurfacePaneFactory.paneID(ofPanel: panelID, in: workspaceID) }
    ) async throws -> [SurfaceProjection] {
        try await projectGroup(
            SurfaceResourceGroup(
                title: "",
                resources: ids,
                remoteWorkspaceID: remoteWorkspaceID
            ),
            into: destination,
            focus: focus,
            paneLookup: paneLookup
        )
    }

    /// Placement-aware group projection. Each member resolves its opaque tab id
    /// against the current catalog; a stale explicit tab is rejected rather than
    /// silently falling back to another view.
    @discardableResult
    func projectGroup(
        _ group: SurfaceResourceGroup,
        into destination: SurfaceDestination,
        focus: Bool,
        paneLookup: PaneLookup = { panelID, workspaceID in SurfacePaneFactory.paneID(ofPanel: panelID, in: workspaceID) }
    ) async throws -> [SurfaceProjection] {
        var projected: [SurfaceProjection] = []
        var firstError: Error?
        var anchor: SurfaceDestination?
        for member in group.placements {
            let id = member.resource
            let target: SurfaceDestination
            if let anchor {
                target = anchor
            } else {
                target = destination
            }
            do {
                let remoteView = try resolveRemoteView(
                    for: member,
                    fallbackWorkspaceID: group.remoteWorkspaceID
                )
                let result = try await project(
                    id,
                    into: target,
                    focus: anchor == nil && focus,
                    reuseExisting: false,
                    remoteView: remoteView
                )
                projected.append(result.projection)
                if anchor == nil {
                    let lead = result.projection
                    if let paneID = paneLookup(lead.panelID, lead.workspaceID) {
                        anchor = .tab(workspaceID: lead.workspaceID, paneID: paneID, index: nil)
                    } else {
                        anchor = .workspace(id: lead.workspaceID, placement: .tab)
                    }
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if projected.isEmpty, let firstError {
            throw firstError
        }
        if projected.isEmpty {
            throw SurfaceCatalogError.destinationNotFound("empty group")
        }
        return projected
    }

    private func resolveRemoteView(
        for member: SurfaceResourcePlacement,
        fallbackWorkspaceID: String?
    ) throws -> SurfaceRemoteView? {
        guard let resource = resources[member.resource], let views = resource.remoteViews else {
            return nil
        }
        if let tabID = member.remoteTabID {
            guard let view = views.first(where: { $0.tabID == tabID }) else {
                throw SurfaceCatalogError.unavailable(
                    member.resource,
                    reason: "remote tab \(tabID) is no longer present"
                )
            }
            if let declaredWorkspace = member.remoteWorkspaceID ?? fallbackWorkspaceID,
               view.workspace.id != declaredWorkspace {
                throw SurfaceCatalogError.unavailable(
                    member.resource,
                    reason: "remote tab \(tabID) is not in workspace \(declaredWorkspace)"
                )
            }
            return view
        }
        let workspaceID = member.remoteWorkspaceID ?? fallbackWorkspaceID
        guard let workspaceID else { return nil }
        let matches = views.filter { $0.workspace.id == workspaceID }
        guard matches.count <= 1 else {
            throw SurfaceCatalogError.ambiguousRemotePlacement(member.resource, workspaceID: workspaceID)
        }
        return matches.first
    }

    /// How a group becomes a new local workspace: the machinery a caller injects so the
    /// layout can be checked without AppKit.
    struct NewWorkspaceHost {
        /// Creates the workspace (⌘N) and reports its starter pane, if any.
        var create: @MainActor (_ title: String) throws -> (workspaceID: UUID, starterPanelID: UUID?)
        /// Bonsplit pane id of a projected panel (the next split anchors on it).
        var paneLookup: PaneLookup
        /// Removes the starter pane once the group's first resource is in place.
        var closeStarter: @MainActor (_ panelID: UUID, _ workspaceID: UUID) -> Void

        @MainActor
        static let app = NewWorkspaceHost(
            create: { title in try SurfacePaneFactory.createLocalWorkspace(title: title) },
            paneLookup: { panelID, workspaceID in SurfacePaneFactory.paneID(ofPanel: panelID, in: workspaceID) },
            closeStarter: { panelID, workspaceID in SurfacePaneFactory.close(panelID: panelID, in: workspaceID) }
        )
    }

    /// Opens a group the way a person expects a remote workspace to open: a new local
    /// workspace named after it, with every terminal and browser as its own pane (not
    /// tabs). The first resource replaces the starter pane; each following one splits the
    /// previous pane, alternating right and down so four terminals land as a 2×2 grid.
    /// Throws when nothing could be projected (the empty workspace is closed again).
    @discardableResult
    func projectGroupAsNewLocalWorkspace(
        _ ids: [SurfaceResourceID],
        title: String,
        focus: Bool,
        host: NewWorkspaceHost,
        remoteWorkspaceID: String? = nil
    ) async throws -> (workspaceID: UUID, projections: [SurfaceProjection]) {
        try await projectGroupAsNewLocalWorkspace(
            SurfaceResourceGroup(title: title, resources: ids, remoteWorkspaceID: remoteWorkspaceID),
            title: title,
            focus: focus,
            host: host
        )
    }

    /// Placement-aware new-workspace projection. The local workspace is created
    /// before the first remote call so the user's destination is deterministic.
    @discardableResult
    func projectGroupAsNewLocalWorkspace(
        _ group: SurfaceResourceGroup,
        title: String,
        focus: Bool,
        host: NewWorkspaceHost
    ) async throws -> (workspaceID: UUID, projections: [SurfaceProjection]) {
        let ids = group.resources
        guard !ids.isEmpty else { throw SurfaceCatalogError.destinationNotFound("empty group") }
        let created = try host.create(title)
        var projected: [SurfaceProjection] = []
        var firstError: Error?
        var lastPane: String?
        for (index, member) in group.placements.enumerated() {
            let id = member.resource
            let target: SurfaceDestination
            if let lastPane {
                let direction: SurfaceSplitDirection = index % 2 == 1 ? .right : .down
                target = .split(workspaceID: created.workspaceID, paneID: lastPane, direction: direction)
            } else {
                target = .workspace(id: created.workspaceID, placement: .split)
            }
            do {
                let remoteView = try resolveRemoteView(
                    for: member,
                    fallbackWorkspaceID: group.remoteWorkspaceID
                )
                let result = try await project(
                    id,
                    into: target,
                    focus: projected.isEmpty && focus,
                    reuseExisting: false,
                    remoteView: remoteView
                )
                if projected.isEmpty, let starter = created.starterPanelID, starter != result.projection.panelID {
                    host.closeStarter(starter, created.workspaceID)
                }
                projected.append(result.projection)
                lastPane = host.paneLookup(result.projection.panelID, created.workspaceID) ?? lastPane
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if projected.isEmpty {
            if let starter = created.starterPanelID { host.closeStarter(starter, created.workspaceID) }
            throw firstError ?? SurfaceCatalogError.destinationNotFound("empty group")
        }
        return (created.workspaceID, projected)
    }
}
