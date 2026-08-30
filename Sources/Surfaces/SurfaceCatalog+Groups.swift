import Foundation

/// A collection of resources that travels as one drag or one "open all": a cmux-tui
/// workspace on a machine, or a local workspace (the panes it projects). A single row is
/// a one-element group, so the sidebar, the drop handler and the menus share one path.
struct SurfaceResourceGroup: Hashable, Codable, Sendable {
    var title: String
    var resources: [SurfaceResourceID]

    init(title: String, resources: [SurfaceResourceID]) {
        self.title = title
        self.resources = resources
    }

    init(single resource: SurfaceResource) {
        self.init(title: resource.title, resources: [resource.id])
    }

    var isEmpty: Bool { resources.isEmpty }
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
        paneLookup: PaneLookup = { panelID, workspaceID in SurfacePaneFactory.paneID(ofPanel: panelID, in: workspaceID) }
    ) async throws -> [SurfaceProjection] {
        var projected: [SurfaceProjection] = []
        var firstError: Error?
        var anchor: SurfaceDestination?
        for id in ids {
            let target: SurfaceDestination
            if let anchor {
                target = anchor
            } else {
                target = destination
            }
            do {
                let result = try await project(id, into: target, focus: anchor == nil && focus, reuseExisting: false)
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
        host: NewWorkspaceHost
    ) async throws -> (workspaceID: UUID, projections: [SurfaceProjection]) {
        guard !ids.isEmpty else { throw SurfaceCatalogError.destinationNotFound("empty group") }
        let created = try host.create(title)
        var projected: [SurfaceProjection] = []
        var firstError: Error?
        var lastPane: String?
        for (index, id) in ids.enumerated() {
            let target: SurfaceDestination
            if let lastPane {
                let direction: SurfaceSplitDirection = index % 2 == 1 ? .right : .down
                target = .split(workspaceID: created.workspaceID, paneID: lastPane, direction: direction)
            } else {
                target = .workspace(id: created.workspaceID, placement: .split)
            }
            do {
                let result = try await project(id, into: target, focus: projected.isEmpty && focus, reuseExisting: false)
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
