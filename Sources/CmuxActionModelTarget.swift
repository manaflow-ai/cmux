import Foundation

/// Immutable model identity for a configured action's workspace and panel.
///
/// Callers resolve routing once and pass the resulting IDs here. The executor
/// resolves and captures the live models before any asynchronous confirmation
/// sheet, so a later focus change cannot redirect the authorized action.
struct CmuxActionModelTarget: Sendable, Equatable {
    let workspaceID: UUID?
    let panelID: UUID?

    init(workspaceID: UUID?, panelID: UUID?) {
        self.workspaceID = workspaceID
        self.panelID = panelID
    }
}
