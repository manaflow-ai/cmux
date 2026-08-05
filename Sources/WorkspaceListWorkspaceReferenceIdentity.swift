import Foundation

struct WorkspaceListWorkspaceReferenceIdentity: Equatable {
    let workspaceId: UUID
    let groupId: UUID?
    let objectIdentifier: ObjectIdentifier

    @MainActor
    init(_ workspace: Workspace) {
        workspaceId = workspace.id
        groupId = workspace.groupId
        objectIdentifier = ObjectIdentifier(workspace)
    }
}
