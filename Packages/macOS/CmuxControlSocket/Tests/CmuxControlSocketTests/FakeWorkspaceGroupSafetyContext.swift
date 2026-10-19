import CmuxSettings
import Foundation
@testable import CmuxControlSocket

@MainActor
final class FakeWorkspaceGroupSafetyContext: ControlCommandContext {
    var createdChildWorkspaceIDs: [UUID]?
    var createdExternalID: String?
    var createResolution: ControlWorkspaceGroupCreateResolution = .notCreated
    var ungroupedGroupIDs: [UUID] = []
    var removeGeneratedAnchor = false
    var deletedGroupIDs: [UUID] = []
    var deleteResult = 2

    func controlCreateWorkspaceGroup(
        routing: ControlRoutingSelectors,
        name: String,
        cwd: String?,
        childWorkspaceIDs: [UUID],
        externalID: String?
    ) -> ControlWorkspaceGroupCreateResolution {
        createdChildWorkspaceIDs = childWorkspaceIDs
        createdExternalID = externalID
        return createResolution
    }

    func controlUngroupWorkspaceGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        removeGeneratedAnchor: Bool
    ) -> ControlWorkspaceGroupUngroupResolution {
        ungroupedGroupIDs.append(groupID)
        self.removeGeneratedAnchor = removeGeneratedAnchor
        return .dissolved(keptWorkspaceCount: 2)
    }

    func controlDeleteWorkspaceGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID
    ) -> Int? {
        deletedGroupIDs.append(groupID)
        return deleteResult
    }
}
