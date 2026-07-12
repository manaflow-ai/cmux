public import CmuxMobileShellModel
public import Observation

/// Serializes hierarchy mutations and recovery across sheet presentations.
@MainActor
@Observable
public final class MobileTerminalReorderGate {
    private var activeReservation: MobileTerminalReorderReservation?
    private var recoveringWorkspaceID: MobileWorkspacePreview.ID?

    /// Workspaces whose acknowledged mutations still need authoritative recovery.
    public private(set) var refreshRequiredWorkspaceIDs: Set<MobileWorkspacePreview.ID> = []

    /// Creates an inactive reorder gate.
    public init() {}

    /// Whether an authoritative reorder is still in flight.
    public var isActive: Bool { activeReservation != nil || recoveringWorkspaceID != nil }

    /// Whether a new close or reorder may start in one workspace.
    public func canMutate(workspaceID: MobileWorkspacePreview.ID) -> Bool {
        !isActive && !refreshRequiredWorkspaceIDs.contains(workspaceID)
    }

    /// Whether one workspace is waiting for authoritative recovery.
    public func requiresRefresh(workspaceID: MobileWorkspacePreview.ID) -> Bool {
        refreshRequiredWorkspaceIDs.contains(workspaceID)
    }

    /// Claims the reorder owner before optimistic UI changes are applied.
    public func reserve(
        workspaceID: MobileWorkspacePreview.ID,
        paneID: MobilePanePreview.ID
    ) -> MobileTerminalReorderReservation? {
        guard canMutate(workspaceID: workspaceID) else { return nil }
        let reservation = MobileTerminalReorderReservation(
            workspaceID: workspaceID,
            paneID: paneID
        )
        activeReservation = reservation
        return reservation
    }

    /// Releases the owner only for the matching reorder operation.
    public func finish(_ reservation: MobileTerminalReorderReservation) {
        guard activeReservation == reservation else { return }
        activeReservation = nil
    }

    /// Keeps hierarchy mutations disabled until an authoritative reload succeeds.
    public func requireRefresh(workspaceID: MobileWorkspacePreview.ID) {
        refreshRequiredWorkspaceIDs.insert(workspaceID)
    }

    /// Claims the single recovery owner after an acknowledged mutation.
    public func beginRecovery(workspaceID: MobileWorkspacePreview.ID) -> Bool {
        guard refreshRequiredWorkspaceIDs.contains(workspaceID), !isActive else { return false }
        recoveringWorkspaceID = workspaceID
        return true
    }

    /// Completes recovery, preserving the dirty state after another failure.
    public func finishRecovery(workspaceID: MobileWorkspacePreview.ID, succeeded: Bool) {
        guard recoveringWorkspaceID == workspaceID else { return }
        recoveringWorkspaceID = nil
        if succeeded {
            refreshRequiredWorkspaceIDs.remove(workspaceID)
        }
    }

    /// Reopens workspaces represented by a successful authoritative list read.
    /// Callers include prior IDs so remotely removed rows cannot leave stale state.
    func reconcileAfterAuthoritativeRefresh(
        workspaceIDs: Set<MobileWorkspacePreview.ID>
    ) {
        refreshRequiredWorkspaceIDs.subtract(workspaceIDs)
    }

    func owns(_ reservation: MobileTerminalReorderReservation) -> Bool {
        activeReservation == reservation
    }
}
