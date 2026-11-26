import CmuxMobileShellModel
import Observation

@Observable
final class WorkspaceGroupDestructiveRequestState {
    struct Request {
        let groupID: MobileWorkspaceGroupPreview.ID
        let action: WorkspaceGroupHeaderPendingDestructiveAction
    }

    private var pending: Request?

    var groupID: MobileWorkspaceGroupPreview.ID? { pending?.groupID }
    var action: WorkspaceGroupHeaderPendingDestructiveAction? { pending?.action }

    func enqueue(
        groupID: MobileWorkspaceGroupPreview.ID,
        action: WorkspaceGroupHeaderPendingDestructiveAction
    ) {
        pending = Request(groupID: groupID, action: action)
    }

    func consume() -> Request? {
        defer { pending = nil }
        return pending
    }

    func clear() {
        pending = nil
    }
}
