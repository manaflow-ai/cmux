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
}
