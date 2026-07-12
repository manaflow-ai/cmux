import CmuxMobileShell
import CmuxMobileShellModel

enum TerminalHierarchyMoveReservationDecision: Equatable {
    case unavailable
    case reserved(MobileTerminalReorderReservation)

    @MainActor
    init(
        snapshot: TerminalHierarchySnapshot,
        paneID: MobilePanePreview.ID,
        reorderGate: MobileTerminalReorderGate
    ) {
        self.init(
            workspaceID: snapshot.workspaceID,
            paneID: paneID,
            reorderGate: reorderGate
        )
    }

    @MainActor
    init(
        workspaceID: MobileWorkspacePreview.ID,
        paneID: MobilePanePreview.ID,
        reorderGate: MobileTerminalReorderGate
    ) {
        guard let reservation = reorderGate.reserve(
            workspaceID: workspaceID,
            paneID: paneID
        ) else {
            self = .unavailable
            return
        }
        self = .reserved(reservation)
    }
}
