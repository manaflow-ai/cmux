import Foundation

struct CommandPaletteForkActionReservation {
    let workspace: Workspace
    let workspaceId: UUID
    let panelId: UUID
    let focus: Bool
    let shouldBeepOnFailure: Bool
}
