public import Foundation
public import Observation
public import Bonsplit

/// The per-workspace pane-tree sub-model: owns the panel registry and the
/// pane-layout bookkeeping the legacy `Workspace` god object kept in its
/// `panels` / `paneLayoutVersion` / `surfaceIdToPanelId` /
/// `lastOrderedPanelIds` stored properties. The split tree itself lives in
/// `BonsplitController`; this model owns the workspace-side mapping onto it.
///
/// The owning `Workspace` composition root holds one instance, forwards its
/// legacy accessors here, and implements `PaneTreeHosting` to receive the
/// property-observer hooks the legacy `@Published` observers provided
/// (objectWillChange/bridge re-emission).
@MainActor
@Observable
public final class PaneTreeModel<Panel> {
    /// Mapping from panel id to the workspace's panel instance (legacy
    /// `Workspace.panels`).
    public var panels: [UUID: Panel] = [:] {
        willSet { host?.panelsWillChange(to: newValue) }
    }

    /// Monotonic counter bumped only when the spatial (left-to-right,
    /// top-to-bottom) order of panels changes without the panel *set*
    /// changing — i.e. a pure drag-reorder of tabs within or across panes.
    /// Membership changes already fire the `panels` observers; pure reorders
    /// mutate only `BonsplitController` state, which is not observed, so
    /// observers (e.g. the mobile workspace-list observer) would otherwise
    /// never learn about a reorder (legacy `Workspace.paneLayoutVersion`).
    public var paneLayoutVersion: Int = 0 {
        willSet { host?.paneLayoutVersionWillChange(to: newValue) }
    }

    /// Mapping from bonsplit `TabID` (surface id) to the owning panel id
    /// (legacy `Workspace.surfaceIdToPanelId`).
    ///
    /// A panel can be mounted under only one bonsplit surface at a time.
    /// Rebinding the same panel id to a new surface id removes any stale
    /// surface entries for that panel so focus and input never resolve two
    /// tabs to one live PTY.
    public private(set) var surfaceIdToPanelId: [TabID: UUID] = [:]

    /// Snapshot of the spatially ordered panel ids from the last geometry
    /// notification, used to gate `paneLayoutVersion` bumps to genuine
    /// reorder events (legacy `Workspace.lastOrderedPanelIds`).
    public var lastOrderedPanelIds: [UUID] = []

    /// Reverse index for targeted panel lookups and stale-surface removal.
    @ObservationIgnored
    private var panelIdToSurfaceId: [UUID: TabID] = [:]

    @ObservationIgnored
    private weak var host: (any PaneTreeHosting<Panel>)?

    /// Creates an empty model; the owning workspace attaches itself as host
    /// before the first mutation.
    public init() {}

    /// Attaches the workspace-side host. Must be called before the first
    /// mutation so the property-observer hooks match the legacy `@Published`
    /// timing from the very first panel insertion.
    public func attach(host: any PaneTreeHosting<Panel>) {
        self.host = host
    }

    /// Binds a bonsplit surface id to a panel id.
    ///
    /// The binding is exclusive by panel id: a live panel can be represented by
    /// only one surface at a time, so rebinding the panel removes stale surface
    /// entries before installing the new owner.
    public func bindSurface(_ surfaceId: TabID, toPanelId panelId: UUID) {
        if let previousSurfaceId = panelIdToSurfaceId[panelId],
           previousSurfaceId != surfaceId {
            surfaceIdToPanelId.removeValue(forKey: previousSurfaceId)
        }
        if let previousPanelId = surfaceIdToPanelId[surfaceId],
           previousPanelId != panelId,
           panelIdToSurfaceId[previousPanelId] == surfaceId {
            panelIdToSurfaceId.removeValue(forKey: previousPanelId)
        }

        surfaceIdToPanelId[surfaceId] = panelId
        panelIdToSurfaceId[panelId] = surfaceId
    }

    /// Removes the mapping for one bonsplit surface id.
    public func removeSurfaceMapping(forSurfaceId surfaceId: TabID) {
        if let panelId = surfaceIdToPanelId.removeValue(forKey: surfaceId),
           panelIdToSurfaceId[panelId] == surfaceId {
            panelIdToSurfaceId.removeValue(forKey: panelId)
        }
    }

    /// Removes every mapping that can still resolve to a closed panel.
    public func removeSurfaceMappings(forPanelId panelId: UUID) {
        if let surfaceId = panelIdToSurfaceId.removeValue(forKey: panelId) {
            surfaceIdToPanelId.removeValue(forKey: surfaceId)
        }
    }

    /// Resolves the owning panel id for a bonsplit surface id (legacy
    /// `Workspace.panelIdFromSurfaceId`).
    public func panelId(forSurfaceId surfaceId: TabID) -> UUID? {
        surfaceIdToPanelId[surfaceId]
    }

    /// Resolves the bonsplit surface id currently mapped to a panel id
    /// (legacy `Workspace.surfaceIdFromPanelId`).
    public func surfaceId(forPanelId panelId: UUID) -> TabID? {
        panelIdToSurfaceId[panelId]
    }
}
