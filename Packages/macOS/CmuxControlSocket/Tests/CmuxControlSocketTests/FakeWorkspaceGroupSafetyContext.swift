import CmuxSettings
import Foundation
@testable import CmuxControlSocket

@MainActor
final class FakeWorkspaceGroupSafetyContext: ControlCommandContext {
    struct CreateCall: Equatable {
        let childWorkspaceIDs: [UUID]
        let childrenExplicit: Bool
    }

    var createCall: CreateCall?
    var createResolution: ControlWorkspaceGroupCreateResolution = .notCreated
    var ungroupedGroupIDs: [UUID] = []
    var deletedGroupIDs: [UUID] = []
    var deleteResult = 2

    func controlCreateWorkspaceGroup(
        routing: ControlRoutingSelectors,
        name: String,
        cwd: String?,
        childWorkspaceIDs: [UUID],
        childrenExplicit: Bool
    ) -> ControlWorkspaceGroupCreateResolution {
        createCall = CreateCall(
            childWorkspaceIDs: childWorkspaceIDs,
            childrenExplicit: childrenExplicit
        )
        return createResolution
    }

    func controlUngroupWorkspaceGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID
    ) -> Bool? {
        ungroupedGroupIDs.append(groupID)
        return true
    }

    func controlDeleteWorkspaceGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID
    ) -> Int? {
        deletedGroupIDs.append(groupID)
        return deleteResult
    }
}
