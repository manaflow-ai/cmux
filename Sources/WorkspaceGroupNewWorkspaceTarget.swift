import Foundation
import CmuxSettings

struct WorkspaceGroupNewWorkspaceTarget {
    let groupId: UUID
    let referenceWorkspaceId: UUID
    let placement: WorkspaceGroupNewPlacement
}
