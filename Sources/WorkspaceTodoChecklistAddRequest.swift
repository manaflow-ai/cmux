import Foundation

struct WorkspaceTodoChecklistAddRequest: Equatable {
    let workspaceID: UUID
    let token: UInt64
}
