public import CmuxMobileShellModel
public import Observation

/// Serializes authoritative terminal reorders across hierarchy presentations.
@MainActor
@Observable
public final class MobileTerminalReorderGate {
    private var activeReservation: MobileTerminalReorderReservation?

    /// Creates an inactive reorder gate.
    public init() {}

    /// Whether an authoritative reorder is still in flight.
    public var isActive: Bool { activeReservation != nil }

    /// Claims the reorder owner before optimistic UI changes are applied.
    public func reserve(
        workspaceID: MobileWorkspacePreview.ID,
        paneID: MobilePanePreview.ID
    ) -> MobileTerminalReorderReservation? {
        guard !isActive else { return nil }
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

    func owns(_ reservation: MobileTerminalReorderReservation) -> Bool {
        activeReservation == reservation
    }
}
