import Foundation
@testable import CmuxWorkspaces

@MainActor
final class ObservedStubTab: WorkspaceTabRepresenting {
    let id = UUID()
    var groupId: UUID?
    var isPinned = false
    var currentDirectory = "/tmp"
}
