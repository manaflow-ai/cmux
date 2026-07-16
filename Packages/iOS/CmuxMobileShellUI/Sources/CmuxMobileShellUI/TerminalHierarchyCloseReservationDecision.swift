import CmuxMobileShell
import CmuxMobileShellModel

enum TerminalHierarchyCloseReservationDecision: Equatable {
    case unavailable
    case reserved(MobileTerminalReorderReservation)

    @MainActor
    init(
        terminalID: MobileTerminalPreview.ID,
        snapshot: TerminalHierarchySnapshot,
        reorderGate: MobileTerminalReorderGate
    ) {
        guard let paneID = snapshot.panes.first(where: { pane in
            pane.rows.contains(where: { $0.id == terminalID })
        })?.id,
        let reservation = reorderGate.reserve(
            workspaceID: snapshot.workspaceID,
            paneID: paneID
        ) else {
            self = .unavailable
            return
        }
        self = .reserved(reservation)
    }
}
