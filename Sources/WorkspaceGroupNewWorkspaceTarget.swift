import CmuxSettings
import Foundation

struct WorkspaceGroupNewWorkspaceTarget {
    let groupId: UUID
    let referenceWorkspaceId: UUID
    let placement: WorkspaceGroupNewPlacement
}
