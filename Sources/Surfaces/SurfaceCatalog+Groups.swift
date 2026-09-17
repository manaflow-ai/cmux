import CmuxCore
import Foundation

/// A collection of resources that travels as one drag or one "open all": a cmux-tui
/// workspace on a machine, or a local workspace (the panes it projects). The canonical
/// payload is typed placements. `resources` and the group workspace id remain as derived
/// compatibility views for older callers and persisted drag records.
struct SurfaceResourceGroup: Hashable, Codable, Sendable {
    let title: String
    let placements: [SurfaceResourcePlacement]
    /// A common placement used by legacy callers that have no per-member tab id.
    let remoteWorkspaceID: String?
    /// True only for a whole workspace row, never a selection of its tabs.
    let representsWorkspace: Bool

    var resources: [SurfaceResourceID] { placements.map(\.resource) }
    var isEmpty: Bool { placements.isEmpty }

    func withRemoteWorkspaceID(_ id: String?) -> Self {
        SurfaceResourceGroup(title: title, placements: placements, remoteWorkspaceID: id ?? remoteWorkspaceID, representsWorkspace: representsWorkspace)
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
        remoteWorkspaceID: String? = nil,
        representsWorkspace: Bool = false
    ) {
        self.representsWorkspace = representsWorkspace
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
        case representsWorkspace
    }

    /// Decode both the placement-aware format and the original id-only format.
    /// Old records are deliberately marked only with their common workspace; if
    /// that workspace has several views, opening fails with an ambiguity error.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        representsWorkspace = try container.decodeIfPresent(Bool.self, forKey: .representsWorkspace) ?? false
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
        try container.encode(representsWorkspace, forKey: .representsWorkspace)
        try container.encode(resources, forKey: .resources)
        try container.encode(placements, forKey: .placements)
        try container.encodeIfPresent(remoteWorkspaceID, forKey: .remoteWorkspaceID)
    }
}

extension SurfaceCatalog {
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
        paneLookup: PaneLookup = { panelID, workspaceID in SurfacePaneFactory.paneID(ofPanel: panelID, in: workspaceID) },
        optimistic: OptimisticPaneHost? = nil
    ) async throws -> [SurfaceProjection] {
        try validateOwnership(of: group.resources, at: destination)
        let scope = beginProjectionMutation(for: group.resources)
        defer { endProjectionMutation(scope) }
        let group = try currentCloudWorkspace(group)?.group ?? group
        try validateOwnership(of: group.resources, at: destination)
        if let optimistic, let reserved = reserveTerminalGroup(group, into: destination, focus: focus, paneLookup: paneLookup, host: optimistic) {
            return reserved
        }
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
        if member.resource.kind == .display, projections.contains(where: {
            $0.resource == member.resource && $0.remoteTabID == nil && $0.remoteWorkspaceID == workspaceID
        }) {
            return nil
        }
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
        /// Reserve-then-attach support. With it, a group of cloud terminals opens as its
        /// whole layout at once and every pane attaches in parallel; without it (headless
        /// tests, socket callers that await authoritative projections) placements are
        /// projected one after another.
        var optimistic: OptimisticPaneHost? = nil

        @MainActor
        static let app = NewWorkspaceHost(
            create: { title in try SurfacePaneFactory.createLocalWorkspace(title: title, titleSource: .auto) },
            paneLookup: { panelID, workspaceID in SurfacePaneFactory.paneID(ofPanel: panelID, in: workspaceID) },
            closeStarter: { panelID, workspaceID in SurfacePaneFactory.close(panelID: panelID, in: workspaceID) },
            applyDividerRatios: { workspaceID, layout in SurfacePaneFactory.applyDividerRatios(layout, in: workspaceID) }
        )

        /// The interactive host: the sidebar and drag-and-drop open layouts optimistically.
        @MainActor
        static let appOptimistic: NewWorkspaceHost = {
            var host = NewWorkspaceHost.app
            host.optimistic = .app
            return host
        }()
    }

    /// Reserves a native pane before the machine round trip and attaches it afterwards.
    /// The reserved pane's projection is recorded up front, so the bound-workspace
    /// coordinator sees the placement as present and never projects a duplicate tab.
    struct OptimisticPaneHost {
        /// A reserved pane at `destination` for a terminal on `machine`, or nil when the
        /// destination is gone. `focus` moves input focus to the new pane.
        var reserve: @MainActor (_ machine: SurfaceMachineID, _ destination: SurfaceDestination, _ focus: Bool) -> CloudTerminalPaneReservation?
        /// Starts the attach loop for a reserved pane whose projection is already recorded.
        var attach: @MainActor (_ reservation: CloudTerminalPaneReservation, _ resource: SurfaceResource, _ remoteTabID: String?) -> Void

        @MainActor
        static let app = OptimisticPaneHost(
            reserve: { machine, destination, focus in
                Workspace.liveWorkspace(id: destination.workspaceID)?
                    .reserveCloudTerminalPane(machine: machine, at: destination, focus: focus)
            },
            attach: { reservation, resource, remoteTabID in
                guard let provider = SurfaceCatalog.shared.provider(for: resource.machine) as? CmuxTuiSurfaceProvider else {
                    Workspace.liveWorkspace(id: reservation.workspaceID)?
                        .failReservedCloudTerminalPane(reservation, error: SurfaceCatalogError.noProvider(resource.machine))
                    return
                }
                provider.attachReservedTerminalPane(reservation, resource: resource, remoteTabID: remoteTabID)
            }
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
        let scope = beginProjectionMutation(for: group.resources)
        defer { endProjectionMutation(scope) }
        let current = try currentCloudWorkspace(group)
        let group = current?.group ?? group
        let title = current?.group.title ?? title
        let layout = current.map { $0.layout } ?? layout
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
    /// Every terminal of `group` gets its pane now: the first at `destination`, the rest
    /// as tabs beside it; each pane's projection is recorded and its attach loop started.
    /// Returns nil (caller falls back to the awaited path) when the group holds anything
    /// but cloud terminals the catalog knows, or the first pane cannot be reserved.
    private func reserveTerminalGroup(
        _ group: SurfaceResourceGroup,
        into destination: SurfaceDestination,
        focus: Bool,
        paneLookup: PaneLookup,
        host: OptimisticPaneHost
    ) -> [SurfaceProjection]? {
        guard let members = reservableTerminals(group) else { return nil }
        var projected: [SurfaceProjection] = []
        var anchor: SurfaceDestination?
        for (placement, resource, remoteView) in members {
            let target = anchor ?? destination
            guard let reservation = host.reserve(resource.machine, target, anchor == nil && focus) else {
                if anchor == nil { return nil }
                continue
            }
            let projection = recordReservedProjection(reservation, placement: placement, remoteView: remoteView)
            projected.append(projection)
            host.attach(reservation, resource, remoteView?.tabID)
            if anchor == nil {
                anchor = paneLookup(reservation.panelID, reservation.workspaceID)
                    .map { .tab(workspaceID: reservation.workspaceID, paneID: $0, index: nil) }
                    ?? .workspace(id: reservation.workspaceID, placement: .tab)
            }
        }
        return projected.isEmpty ? nil : projected
    }

    /// The group's members as (placement, resource, exact remote view) when every one is a
    /// cloud terminal the catalog knows; nil otherwise, so browsers and unknown resources
    /// keep the awaited path.
    private func reservableTerminals(_ group: SurfaceResourceGroup) -> [(SurfaceResourcePlacement, SurfaceResource, SurfaceRemoteView?)]? {
        var members: [(SurfaceResourcePlacement, SurfaceResource, SurfaceRemoteView?)] = []
        for placement in group.placements {
            guard !placement.resource.machine.isLocal,
                  let resource = resources[placement.resource],
                  resource.kind == .terminal,
                  let remoteView = try? resolveRemoteView(for: placement, fallbackWorkspaceID: group.remoteWorkspaceID) else {
                return nil
            }
            members.append((placement, resource, remoteView))
        }
        return members.isEmpty ? nil : members
    }

    /// Records the projection a reserved pane will carry once attached. Recording it now
    /// keeps the placement out of the coordinator's "missing" plan while the attach runs.
    @discardableResult
    func recordReservedProjection(
        _ reservation: CloudTerminalPaneReservation,
        placement: SurfaceResourcePlacement,
        remoteView: SurfaceRemoteView?
    ) -> SurfaceProjection {
        let projection = SurfaceProjection(
            resource: placement.resource,
            workspaceID: reservation.workspaceID,
            panelID: reservation.panelID,
            remoteWorkspaceID: remoteView?.workspace.id ?? placement.remoteWorkspaceID,
            remoteTabID: remoteView?.tabID ?? placement.remoteTabID
        )
        record(projection)
        return projection
    }

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
        /// projected at all. With an optimistic host every pane of the layout is reserved
        /// synchronously first, so the workspace opens looking the way it does on the
        /// machine, and the terminals attach in parallel behind those panes.
        mutating func run(_ layout: SurfaceProjectionLayout) async -> SurfaceProjectionLayout? {
            if let optimistic = host.optimistic, let realized = reserveAll(layout, host: optimistic) {
                return realized
            }
            // The first placement takes the starter pane's place, exactly as the grid walk does.
            guard let root = await consumeFirst(of: layout, into: .workspace(id: workspaceID, placement: .split)) else {
                return nil
            }
            return await build(root.remaining, in: root.paneID)
        }

        /// Reserves every pane of `layout` in the same order the awaited walk projects them,
        /// records their projections, and starts every attach. Nil when the layout holds
        /// anything but known cloud terminals, so the awaited walk takes over untouched.
        private mutating func reserveAll(_ layout: SurfaceProjectionLayout, host: OptimisticPaneHost) -> SurfaceProjectionLayout? {
            let members = SurfaceResourceGroup(title: group.title, placements: layout.placements, remoteWorkspaceID: group.remoteWorkspaceID)
            guard let resolved = catalog.reservableTerminals(members) else { return nil }
            var views: [SurfaceResourcePlacement: (SurfaceResource, SurfaceRemoteView?)] = [:]
            for (placement, resource, view) in resolved { views[placement] = (resource, view) }
            var pending: [(CloudTerminalPaneReservation, SurfaceResource, SurfaceRemoteView?)] = []
            @MainActor func reserve(_ placement: SurfaceResourcePlacement, into destination: SurfaceDestination) -> String?? {
                guard let (resource, view) = views[placement] else { return nil }
                guard let reservation = host.reserve(resource.machine, destination, projected.isEmpty && focus) else { return nil }
                if projected.isEmpty, let starterPanelID, starterPanelID != reservation.panelID {
                    self.host.closeStarter(starterPanelID, workspaceID)
                }
                projected.append(catalog.recordReservedProjection(reservation, placement: placement, remoteView: view))
                pending.append((reservation, resource, view))
                return .some(self.host.paneLookup(reservation.panelID, workspaceID))
            }
            // Same shape as consumeFirst/build, without the awaits: the first placement of a
            // node makes its pane; a leaf's rest become tabs; a split's second half opens
            // beside the first's pane.
            @MainActor func consumeFirst(of node: SurfaceProjectionLayout, into destination: SurfaceDestination) -> (paneID: String?, remaining: SurfaceProjectionLayout)? {
                switch node {
                case .leaf(let placements):
                    for (offset, placement) in placements.enumerated() {
                        guard let paneID = reserve(placement, into: destination) else { continue }
                        return (paneID, .leaf(placements: Array(placements[(offset + 1)...])))
                    }
                    return nil
                case .split(let direction, let ratio, let first, let second):
                    if let consumed = consumeFirst(of: first, into: destination) {
                        return (consumed.paneID, .split(direction: direction, ratio: ratio, first: consumed.remaining, second: second))
                    }
                    return consumeFirst(of: second, into: destination)
                }
            }
            @MainActor func build(_ node: SurfaceProjectionLayout, in paneID: String?) -> SurfaceProjectionLayout {
                switch node {
                case .leaf(let placements):
                    for placement in placements { _ = reserve(placement, into: tabDestination(paneID)) }
                    return node
                case .split(let direction, let ratio, let first, let second):
                    guard let consumed = consumeFirst(of: second, into: splitDestination(paneID, direction)) else {
                        return build(first, in: paneID)
                    }
                    let builtFirst = build(first, in: paneID)
                    let builtSecond = build(consumed.remaining, in: consumed.paneID)
                    return .split(direction: direction, ratio: ratio, first: builtFirst, second: builtSecond)
                }
            }
            guard let root = consumeFirst(of: layout, into: .workspace(id: workspaceID, placement: .split)) else { return nil }
            let realized = build(root.remaining, in: root.paneID)
            for (reservation, resource, view) in pending { host.attach(reservation, resource, view?.tabID) }
            return realized
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
