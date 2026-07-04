import Foundation
import CmuxWorkspaces

struct WorkspaceGroupMoveToMenuState: Equatable {
    let groups: [WorkspaceGroupMenuSnapshotItem]

    var isDisabled: Bool {
        groups.isEmpty
    }

    var rendersSubmenu: Bool {
        !groups.isEmpty
    }
}
