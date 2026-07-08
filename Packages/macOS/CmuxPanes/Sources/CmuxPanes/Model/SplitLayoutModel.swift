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
/// stored properties used the old Combine-backed observation path on the legacy god object, so this
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

    // MARK: Detach choreography

    /// Marks a surface as mid-detach so the close pipeline routes its tab
    /// close into a transfer capture instead of a destructive close (legacy
    /// `detachingTabIds.insert(tabId)` in `Workspace.detachSurface`).
    public func markDetaching(_ tabId: TabID) {
        detachingTabIds.insert(tabId)
    }

    /// Opens one detach-close transaction (legacy
    /// `activeDetachCloseTransactions += 1`); always pair with
    /// ``closeDetachCloseTransaction()``.
    public func openDetachCloseTransaction() {
        activeDetachCloseTransactions += 1
    }

    /// Closes one detach-close transaction, clamping at zero (legacy
    /// `activeDetachCloseTransactions = max(0, activeDetachCloseTransactions - 1)`).
    public func closeDetachCloseTransaction() {
        activeDetachCloseTransactions = max(0, activeDetachCloseTransactions - 1)
    }

    /// Rolls back a failed detach: clears the mid-detach mark and discards
    /// any transfer captured for the surface (legacy failure path of
    /// `Workspace.detachSurface`).
    public func cancelDetach(_ tabId: TabID) {
        detachingTabIds.remove(tabId)
        pendingDetachedSurfaces.removeValue(forKey: tabId)
    }

    /// Consumes the mid-detach mark for a closing surface, reporting whether
    /// the close is part of a detach: either the surface itself was marked,
    /// or a detach-close transaction is open (legacy
    /// `detachingTabIds.remove(tabId) != nil || isDetachingCloseTransaction`).
    public func consumeDetachingMark(_ tabId: TabID) -> Bool {
        detachingTabIds.remove(tabId) != nil || isDetachingCloseTransaction
    }

    /// Captures the transfer payload for a surface mid-detach (legacy
    /// `pendingDetachedSurfaces[tabId] = transfer` in the close pipeline).
    public func storeDetachedTransfer(_ transfer: Transfer, for tabId: TabID) {
        pendingDetachedSurfaces[tabId] = transfer
    }

    /// Takes the captured transfer payload for a detached surface, if the
    /// close pipeline produced one (legacy
    /// `pendingDetachedSurfaces.removeValue(forKey: tabId)`).
    public func takeDetachedTransfer(_ tabId: TabID) -> Transfer? {
        pendingDetachedSurfaces.removeValue(forKey: tabId)
    }
}
