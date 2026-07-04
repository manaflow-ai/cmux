import Foundation
@testable import CmuxWorkspaces

@MainActor
final class UngroupPromotionTab: WorkspaceTabRepresenting {
    let id = UUID()
    var groupId: UUID?
    var isPinned: Bool
    let currentDirectory = "/tmp"

    init(groupId: UUID?, isPinned: Bool = false) {
        self.groupId = groupId
        self.isPinned = isPinned
    }
}
