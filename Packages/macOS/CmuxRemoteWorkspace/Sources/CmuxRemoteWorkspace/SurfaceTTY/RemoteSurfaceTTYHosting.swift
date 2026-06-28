public import Foundation

/// The live-workspace seam the ``RemoteSurfaceTTYCoordinator`` reaches back
/// through to read and push the slice of workspace state its pending
/// remote-surface TTY / port-kick bookkeeping bodies touch.
///
/// The coordinator owns the decision/bookkeeping logic of the pending-TTY and
/// pending-port-kick paths (`rememberPendingRemoteSurfaceTTY`,
/// `rememberPendingRemoteSurfacePortKick`, `applyPendingRemoteSurfaceTTYIfNeeded`,
/// `applyPendingRemoteSurfacePortKickIfNeeded`, and `applyBootstrapRemoteTTY`).
/// Everything those bodies read or mutate that cannot move down a module
/// boundary is reproduced here as one read or push:
///
/// - the four pending stored fields (`pendingRemoteSurfaceTTYName/SurfaceId`,
///   `pendingRemoteSurfacePortKickReason/SurfaceId`), witnessed get/set so they
///   stay app-side (they are also reset on connect/disconnect outside this
///   slice);
/// - the per-surface TTY-name map, read per-key and written per-key exactly as
///   the legacy bodies did;
/// - the active remote-terminal surface id set and the focused panel id, both
///   read to pick the bootstrap candidate surface;
/// - the port-scan TTY sync and the per-panel port-scan kick, which forward to
///   the sibling `RemoteSurfaceCoordinator` app-side;
/// - the default `.command` port-kick reason, supplied app-side so the
///   coordinator never names ``PortScanKickReason`` (it lives in a package above
///   this one in the graph, so the reason type is the seam's associated type).
///
/// `@MainActor` for the same reason as the sibling seams: every lifted body was
/// a plain method on the `@MainActor` `Workspace`, so all of its reads, writes,
/// and pushes already ran on the main actor. The coordinator never imports the
/// `Workspace` type; it is witnessed in `Workspace+RemoteSurfaceTTYHosting.swift`.
@MainActor
public protocol RemoteSurfaceTTYHosting: AnyObject {
    /// The port-scan kick reason type (the app's `PortScanKickReason`, which
    /// lives above this package in the graph and so is carried as an associated
    /// type rather than imported).
    associatedtype PortKickReason

    // MARK: - Pending stored fields (witnessed get/set)

    /// The pending remote-surface TTY name awaiting a surface to bind to.
    var hostPendingRemoteSurfaceTTYName: String? { get set }

    /// The requested surface id the pending TTY name should bind to, or `nil`.
    var hostPendingRemoteSurfaceTTYSurfaceId: UUID? { get set }

    /// The pending remote-surface port-kick reason awaiting a TTY-named surface.
    var hostPendingRemoteSurfacePortKickReason: PortKickReason? { get set }

    /// The requested surface id the pending port-kick should target, or `nil`.
    var hostPendingRemoteSurfacePortKickSurfaceId: UUID? { get set }

    // MARK: - Per-surface TTY names (per-key access)

    /// The recorded TTY name for `panelId`. Faithful read of
    /// `surfaceTTYNames[panelId]`.
    func hostSurfaceTTYName(forPanel panelId: UUID) -> String?

    /// Records `name` as the TTY name for `panelId`. Faithful equivalent of
    /// `surfaceTTYNames[panelId] = name`.
    func hostSetSurfaceTTYName(_ name: String, forPanel panelId: UUID)

    // MARK: - Bootstrap candidate selection

    /// The set of surface ids with live remote terminals.
    var hostActiveRemoteTerminalSurfaceIds: Set<UUID> { get }

    /// The currently focused panel id, or `nil`.
    var hostFocusedPanelId: UUID? { get }

    /// The default `.command` port-kick reason, supplied app-side so the
    /// coordinator does not name the reason type.
    var hostDefaultCommandPortKickReason: PortKickReason { get }

    // MARK: - Port-scan forwards

    /// Re-syncs the remote port-scan TTY list. Faithful forward to
    /// `Workspace.syncRemotePortScanTTYs()`.
    func hostSyncRemotePortScanTTYs()

    /// Kicks a remote port scan on `panelId` with `reason`. Faithful forward to
    /// `Workspace.kickRemotePortScan(panelId:reason:)`.
    func hostKickRemotePortScan(panelId: UUID, reason: PortKickReason)
}
