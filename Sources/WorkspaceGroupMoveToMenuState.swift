import Foundation

struct WorkspaceGroupMoveToMenuState: Equatable {
    let groups: [WorkspaceGroupMenuSnapshot.Item]

    var isDisabled: Bool {
        groups.isEmpty
    }

    var rendersSubmenu: Bool {
        !groups.isEmpty
    }
}
