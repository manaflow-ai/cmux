import CmuxMobileShellModel
import SwiftUI

struct WorkspaceListDropState {
    var payload: MobileWorkspaceDropPayload?
    var target: MobileWorkspaceDropTarget?
    var rows: [MobileWorkspaceDropRowFrame] = []
    var viewportSize = CGSize.zero

    var feedbackIdentity: String? {
        guard let target else { return nil }
        let indicatorKind: String
        switch target.indicator.kind {
        case .insertLine:
            indicatorKind = "line"
        case .highlightGroup(let groupID):
            indicatorKind = "group:\(groupID.rawValue)"
        }
        return [
            target.intent.groupID?.rawValue ?? "root",
            target.intent.beforeWorkspaceID?.rawValue ?? "end",
            target.intent.movesGroup ? "groupMove" : "workspaceMove",
            target.isNoOp ? "noop" : "move",
            indicatorKind,
        ].joined(separator: "|")
    }
}
