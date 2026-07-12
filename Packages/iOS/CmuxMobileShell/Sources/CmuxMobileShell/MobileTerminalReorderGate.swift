public import CmuxMobileShellModel
public import Observation

/// Serializes hierarchy mutations and recovery across sheet presentations.
@MainActor
@Observable
public final class MobileTerminalReorderGate {
    private var activeReservation: MobileTerminalReorderReservation?
    private var recoveryInFlight = false

    /// Whether an acknowledged mutation still needs authoritative recovery.
    public private(set) var requiresRefresh = false

    /// Creates an inactive reorder gate.
    public init() {}

    /// Whether an authoritative reorder is still in flight.
    public var isActive: Bool { activeReservation != nil || recoveryInFlight }

    /// Whether a new close or reorder may start from the visible hierarchy.
    public var canMutate: Bool { !isActive && !requiresRefresh }

    /// Claims the reorder owner before optimistic UI changes are applied.
    public func reserve(
        workspaceID: MobileWorkspacePreview.ID,
        paneID: MobilePanePreview.ID
    ) -> MobileTerminalReorderReservation? {
        guard canMutate else { return nil }
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
    public func requireRefresh() {
        requiresRefresh = true
    }

    /// Claims the single recovery owner after an acknowledged mutation.
    public func beginRecovery() -> Bool {
        guard requiresRefresh, !isActive else { return false }
        recoveryInFlight = true
        return true
    }

    /// Completes recovery, preserving the dirty state after another failure.
    public func finishRecovery(succeeded: Bool) {
        guard recoveryInFlight else { return }
        recoveryInFlight = false
        requiresRefresh = !succeeded
    }

    func owns(_ reservation: MobileTerminalReorderReservation) -> Bool {
        activeReservation == reservation
    }
}
