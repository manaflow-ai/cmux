import CmuxMobileShellModel
import Observation

@Observable
final class WorkspaceGroupDestructiveRequestState {
    var groupID: MobileWorkspaceGroupPreview.ID?
    var action: WorkspaceGroupHeaderPendingDestructiveAction?

    func consume() -> (
        groupID: MobileWorkspaceGroupPreview.ID,
        action: WorkspaceGroupHeaderPendingDestructiveAction
    )? {
        guard let groupID, let action else {
            return nil
        }
        clear()
        return (groupID, action)
    }

    func clear() {
        groupID = nil
        action = nil
    }
}
