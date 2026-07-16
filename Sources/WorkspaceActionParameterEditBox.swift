import AppKit
import Foundation

/// Payload for an explicit edit-parameters menu action.
@MainActor
final class WorkspaceActionParameterEditBox: NSObject {
    let windowId: UUID
    let actionID: String
    let actionTitle: String

    init(windowId: UUID, actionID: String, actionTitle: String) {
        self.windowId = windowId
        self.actionID = actionID
        self.actionTitle = actionTitle
    }
}
