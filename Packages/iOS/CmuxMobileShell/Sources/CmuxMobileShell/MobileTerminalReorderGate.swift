public import CmuxMobileShellModel
public import Observation

/// Serializes hierarchy mutations and recovery across sheet presentations.
@MainActor
@Observable
public final class MobileTerminalReorderGate {
    private var activeReservation: MobileTerminalReorderReservation?
    private var recoveryInFlight = false

    /// Workspace whose acknowledged mutation still needs authoritative recovery.
    public private(set) var refreshRequiredWorkspaceID: MobileWorkspacePreview.ID?

    /// Creates an inactive reorder gate.
    public init() {}

    /// Whether an authoritative reorder is still in flight.
    public var isActive: Bool { activeReservation != nil || recoveryInFlight }

    /// Whether a new close or reorder may start in one workspace.
    public func canMutate(workspaceID: MobileWorkspacePreview.ID) -> Bool {
        !isActive && refreshRequiredWorkspaceID != workspaceID
    }

    /// Whether one workspace is waiting for authoritative recovery.
    public func requiresRefresh(workspaceID: MobileWorkspacePreview.ID) -> Bool {
        refreshRequiredWorkspaceID == workspaceID
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
        refreshRequiredWorkspaceID = workspaceID
    }

    /// Claims the single recovery owner after an acknowledged mutation.
    public func beginRecovery(workspaceID: MobileWorkspacePreview.ID) -> Bool {
        guard refreshRequiredWorkspaceID == workspaceID, !isActive else { return false }
        recoveryInFlight = true
        return true
    }

    /// Completes recovery, preserving the dirty state after another failure.
    public func finishRecovery(workspaceID: MobileWorkspacePreview.ID, succeeded: Bool) {
        guard recoveryInFlight, refreshRequiredWorkspaceID == workspaceID else { return }
        recoveryInFlight = false
        if succeeded {
            refreshRequiredWorkspaceID = nil
        }
    }

    func owns(_ reservation: MobileTerminalReorderReservation) -> Bool {
        activeReservation == reservation
    }
}
