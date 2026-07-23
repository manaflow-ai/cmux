import Foundation

/// Immutable display and action data for one live agent session in the computer-use menu.
struct ComputerUseMenuBarRow: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let sessionID: String
    let workspaceID: UUID
    let surfaceID: UUID
    let targetIdentity: ComputerUseTargetIdentity?

    func withTargetIdentity(_ targetIdentity: ComputerUseTargetIdentity?) -> ComputerUseMenuBarRow {
        ComputerUseMenuBarRow(
            id: id,
            title: title,
            sessionID: sessionID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            targetIdentity: targetIdentity
        )
    }
}
