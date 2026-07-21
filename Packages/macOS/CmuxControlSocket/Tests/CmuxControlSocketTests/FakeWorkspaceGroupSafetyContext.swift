import CmuxSettings
import Foundation
@testable import CmuxControlSocket

@MainActor
final class FakeWorkspaceGroupSafetyContext: ControlCommandContext {
    struct CreateCall: Equatable {
        let childWorkspaceIDs: [UUID]
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
        childWorkspaceIDs: [UUID]
    ) -> ControlWorkspaceGroupCreateResolution {
        createCall = CreateCall(
            childWorkspaceIDs: childWorkspaceIDs
        )
        return createResolution
    }

    func controlUngroupWorkspaceGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID
    ) -> Int? {
        ungroupedGroupIDs.append(groupID)
        return 2
    }

    func controlDeleteWorkspaceGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID
    ) -> Int? {
        deletedGroupIDs.append(groupID)
        return deleteResult
    }
}
