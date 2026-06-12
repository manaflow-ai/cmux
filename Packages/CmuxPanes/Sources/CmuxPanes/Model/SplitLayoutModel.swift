public import Foundation
public import Observation
public import Bonsplit

/// The per-workspace split-layout sub-model: owns the split/detach
/// choreography state the legacy `Workspace` god object kept as loose
/// stored properties (`isProgrammaticSplit`, `detachingTabIds`,
/// `pendingDetachedSurfaces`, `activeDetachCloseTransactions`). The split
/// tree itself lives in `BonsplitController`; this model owns the
/// workspace-side bookkeeping around it.
///
/// `Transfer` is the window's detached-surface transfer payload type (the
/// app target's `Workspace.DetachedSurfaceTransfer`, which carries panel
/// references and app-domain snapshots, so it stays app-side). None of the
/// stored properties were `@Published` on the legacy god object, so this
/// storage move carries no observer-parity hooks.
@MainActor
@Observable
public final class SplitLayoutModel<Transfer> {
    /// True while a programmatic split is in flight, suppressing
    /// auto-creation in the `didSplitPane` delegate callback (legacy
    /// `Workspace.isProgrammaticSplit`).
    public var isProgrammaticSplit = false

    /// Surface ids currently being detached for transfer to another
    /// workspace (legacy `Workspace.detachingTabIds`).
    public var detachingTabIds: Set<TabID> = []

    /// Captured transfer payloads for surfaces mid-detach, keyed by surface
    /// id (legacy `Workspace.pendingDetachedSurfaces`).
    public var pendingDetachedSurfaces: [TabID: Transfer] = [:]

    /// Count of nested detach-close transactions currently open (legacy
    /// `Workspace.activeDetachCloseTransactions`).
    public var activeDetachCloseTransactions: Int = 0

    /// True while any detach-close transaction is open (legacy
    /// `Workspace.isDetachingCloseTransaction`).
    public var isDetachingCloseTransaction: Bool { activeDetachCloseTransactions > 0 }

    /// Creates an idle model; the owning workspace drives it from its
    /// split/detach flows.
    public init() {}
}
