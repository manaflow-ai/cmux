import CmuxCore
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
    /// collapse two tabs that point at the same terminal. Order matches the
    /// Cloud sidebar: panes in layout order, the shown tab before that pane's
    /// hidden tabs, then pane-less resources in kind order.
    func remoteWorkspaceGroup(
        machine: SurfaceMachineID,
        workspaceID: String
    ) throws -> SurfaceResourceGroup {
        let machineSnapshot = snapshot
        let machineInfo = machineSnapshot.machines.first { $0.id == machine }
        var workspace = machineInfo?.remoteWorkspaces?.first { $0.id == workspaceID }
        let resources = machineSnapshot.resources(on: machine)

        struct Candidate {
            let placement: SurfaceResourcePlacement
            let layout: RemoteWorkspacePlacement
        }
        let orderedKinds: [SurfaceResourceKind] = [.terminal, .browser, .display]
        var candidates: [Candidate] = []
        for kind in orderedKinds {
            let kindOrder = kind == .terminal ? 0 : (kind == .browser ? 1 : 2)
            for resource in resources where resource.kind == kind {
                if let views = resource.remoteViews, !views.isEmpty {
                    for view in views where view.workspace.id == workspaceID {
                        workspace = workspace ?? view.workspace
                        candidates.append(Candidate(
                            placement: SurfaceResourcePlacement(resource: resource.id, remoteView: view),
                            layout: RemoteWorkspacePlacement(
                                screenID: view.screenID,
                                paneID: view.paneID,
                                screenIndex: view.screenIndex,
                                paneIndex: view.paneIndex,
                                tabIndex: view.index,
                                focused: view.focused == true,
                                kindOrder: kindOrder
                            )
                        ))
                    }
                } else if let resourceWorkspace = resource.remoteWorkspace,
                          resourceWorkspace.id == workspaceID {
                    workspace = workspace ?? resourceWorkspace
                    candidates.append(Candidate(
                        placement: SurfaceResourcePlacement(
                            resource: resource.id,
                            remoteWorkspaceID: workspaceID
                        ),
                        layout: RemoteWorkspacePlacement(kindOrder: kindOrder)
                    ))
                }
            }
        }

        guard let workspace else {
            throw SurfaceCatalogError.destinationNotFound(
                "workspace \(workspaceID) on \(machine.rawValue)"
            )
        }
        guard !candidates.isEmpty else {
            throw SurfaceCatalogError.destinationNotFound(
                "workspace \(workspaceID) on \(machine.rawValue) has no projectable resources"
            )
        }
        let layout = RemoteWorkspaceLayout(placements: candidates.map(\.layout))
        let placements = layout.rows.flatMap { row in
            [candidates[row.shownIndex].placement] + row.hiddenIndices.map { candidates[$0].placement }
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
        // Unknown resources are skipped by the group projector. Once a resource exists,
        // delegate placement validation to the catalog's single resolver so explicit IDs
        // cannot silently fall back when remote view metadata is absent.
        guard resources[member.resource] != nil else {
            return nil
        }
        if let tabID = member.remoteTabID {
            return try remoteView(
                for: member.resource,
                tabID: tabID,
                workspaceID: member.remoteWorkspaceID ?? fallbackWorkspaceID
            )
        }
        let workspaceID = member.remoteWorkspaceID ?? fallbackWorkspaceID
        guard let workspaceID else { return nil }
        return try remoteView(for: member.resource, workspaceID: workspaceID)
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
        /// Sets the local dividers to the ratios of a layout the walk just built (the tree
        /// actually realized, so a split that failed to materialize is not in it). Defaults
        /// to a no-op so a headless test host can check the walk without a pane engine.
        var applyDividerRatios: @MainActor (_ workspaceID: UUID, _ layout: SurfaceProjectionLayout) -> Void = { _, _ in }

        @MainActor
        static let app = NewWorkspaceHost(
            create: { title in try SurfacePaneFactory.createLocalWorkspace(title: title) },
            paneLookup: { panelID, workspaceID in SurfacePaneFactory.paneID(ofPanel: panelID, in: workspaceID) },
            closeStarter: { panelID, workspaceID in SurfacePaneFactory.close(panelID: panelID, in: workspaceID) },
            applyDividerRatios: { workspaceID, layout in SurfacePaneFactory.applyDividerRatios(layout, in: workspaceID) }
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
    ///
    /// With a `layout` (the machine screen's geometry, `CloudWorkspaceLayoutTranslator`),
    /// the tree decides everything the grid used to guess: which pane each placement
    /// lands in, which pane is split for the next one and in which direction, and the
    /// ratio every divider gets — so the workspace opens looking the way it does on the
    /// machine. Without one, the right/down alternation below still applies.
    @discardableResult
    func projectGroupAsNewLocalWorkspace(
        _ group: SurfaceResourceGroup,
        title: String,
        focus: Bool,
        host: NewWorkspaceHost,
        layout: SurfaceProjectionLayout? = nil
    ) async throws -> (workspaceID: UUID, projections: [SurfaceProjection]) {
        let ids = group.resources
        guard !ids.isEmpty else { throw SurfaceCatalogError.destinationNotFound("empty group") }
        let created = try host.create(title)
        if let layout {
            var walk = LayoutProjectionWalk(
                catalog: self,
                group: group,
                workspaceID: created.workspaceID,
                starterPanelID: created.starterPanelID,
                focus: focus,
                host: host
            )
            let realized = await walk.run(layout.includingMissingPlacements(group.placements))
            if walk.projected.isEmpty {
                if let starter = created.starterPanelID { host.closeStarter(starter, created.workspaceID) }
                throw walk.firstError ?? SurfaceCatalogError.destinationNotFound("empty group")
            }
            if let realized { host.applyDividerRatios(created.workspaceID, realized) }
            return (created.workspaceID, walk.projected)
        }
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

    /// One layout-driven new-workspace projection (`projectGroupAsNewLocalWorkspace(_:layout:)`).
    ///
    /// Splits are created parent-first: a split node makes its second pane BEFORE its
    /// first child's own splits subdivide the first pane. That is the order in which the
    /// local Bonsplit tree ends up mirroring the layout node for node (the same order
    /// `Workspace.applyCustomLayout` builds cmux.json layouts in), which is what lets the
    /// ratio pass walk both trees in step afterwards. The walk returns the tree it really
    /// built, so a placement that failed to materialize cannot misalign the two.
    @MainActor
    private struct LayoutProjectionWalk {
        let catalog: SurfaceCatalog
        let group: SurfaceResourceGroup
        let workspaceID: UUID
        let starterPanelID: UUID?
        let focus: Bool
        let host: NewWorkspaceHost
        private(set) var projected: [SurfaceProjection] = []
        private(set) var firstError: Error?

        init(catalog: SurfaceCatalog, group: SurfaceResourceGroup, workspaceID: UUID, starterPanelID: UUID?, focus: Bool, host: NewWorkspaceHost) {
            self.catalog = catalog
            self.group = group
            self.workspaceID = workspaceID
            self.starterPanelID = starterPanelID
            self.focus = focus
            self.host = host
        }

        /// Builds `layout` into the fresh workspace; the realized tree, or nil when nothing
        /// projected at all.
        mutating func run(_ layout: SurfaceProjectionLayout) async -> SurfaceProjectionLayout? {
            // The first placement takes the starter pane's place, exactly as the grid walk does.
            guard let root = await consumeFirst(of: layout, into: .workspace(id: workspaceID, placement: .split)) else {
                return nil
            }
            return await build(root.remaining, in: root.paneID)
        }

        /// Projects one placement, recording the first failure; nil when it did not land.
        private mutating func projectOne(_ placement: SurfaceResourcePlacement, into destination: SurfaceDestination) async -> SurfaceProjection? {
            do {
                let remoteView = try catalog.resolveRemoteView(for: placement, fallbackWorkspaceID: group.remoteWorkspaceID)
                let result = try await catalog.project(
                    placement.resource,
                    into: destination,
                    focus: projected.isEmpty && focus,
                    reuseExisting: false,
                    remoteView: remoteView
                )
                if projected.isEmpty, let starterPanelID, starterPanelID != result.projection.panelID {
                    host.closeStarter(starterPanelID, workspaceID)
                }
                projected.append(result.projection)
                return result.projection
            } catch {
                if firstError == nil { firstError = error }
                return nil
            }
        }

        /// Projects the first placement of `node` that materializes at `destination` — the
        /// one that creates the pane — and returns that pane with what is left of the node
        /// to fill in around it. A leaf whose every placement fails is dropped so its
        /// sibling takes the slot; nil when nothing in the node could be projected.
        private mutating func consumeFirst(
            of node: SurfaceProjectionLayout,
            into destination: SurfaceDestination
        ) async -> (paneID: String?, remaining: SurfaceProjectionLayout)? {
            switch node {
            case .leaf(let placements):
                for (offset, placement) in placements.enumerated() {
                    guard let projection = await projectOne(placement, into: destination) else { continue }
                    let paneID = host.paneLookup(projection.panelID, workspaceID)
                    return (paneID, .leaf(placements: Array(placements[(offset + 1)...])))
                }
                return nil
            case .split(let direction, let ratio, let first, let second):
                if let consumed = await consumeFirst(of: first, into: destination) {
                    return (consumed.paneID, .split(direction: direction, ratio: ratio, first: consumed.remaining, second: second))
                }
                return await consumeFirst(of: second, into: destination)
            }
        }

        /// Fills `node` in around `paneID`, whose content is already the node's first
        /// placement: a leaf's remaining placements become tabs there; a split first makes
        /// its second pane beside `paneID`, then fills both halves. Returns the tree as built.
        private mutating func build(_ node: SurfaceProjectionLayout, in paneID: String?) async -> SurfaceProjectionLayout {
            switch node {
            case .leaf(let placements):
                for placement in placements {
                    _ = await projectOne(placement, into: tabDestination(paneID))
                }
                return node
            case .split(let direction, let ratio, let first, let second):
                guard let consumed = await consumeFirst(of: second, into: splitDestination(paneID, direction)) else {
                    // Nothing of the second half could open: the first half keeps the whole slot.
                    return await build(first, in: paneID)
                }
                let builtFirst = await build(first, in: paneID)
                let builtSecond = await build(consumed.remaining, in: consumed.paneID)
                return .split(direction: direction, ratio: ratio, first: builtFirst, second: builtSecond)
            }
        }

        /// A pane the factory could not name falls back to the workspace's focused pane,
        /// as the tab-anchored group walk above does.
        private func tabDestination(_ paneID: String?) -> SurfaceDestination {
            guard let paneID else { return .workspace(id: workspaceID, placement: .tab) }
            return .tab(workspaceID: workspaceID, paneID: paneID, index: nil)
        }

        private func splitDestination(_ paneID: String?, _ direction: SurfaceSplitDirection) -> SurfaceDestination {
            guard let paneID else { return .workspace(id: workspaceID, placement: .split) }
            return .split(workspaceID: workspaceID, paneID: paneID, direction: direction)
        }
    }
}
