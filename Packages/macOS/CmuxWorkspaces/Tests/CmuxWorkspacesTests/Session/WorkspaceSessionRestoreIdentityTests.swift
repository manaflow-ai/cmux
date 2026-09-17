import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite("WorkspaceSessionRestoreIdentity")
struct WorkspaceSessionRestoreIdentityTests {
    @Test("preserves an unreserved persisted workspace id")
    func preservesUnreservedPersistedWorkspaceId() {
        let identitySelector = WorkspaceSessionRestoreIdentity()
        let persistedWorkspaceId = UUID()
        var reservedWorkspaceIds: Set<UUID> = []

        let restoredWorkspaceId = identitySelector.restoredWorkspaceId(
            persistedWorkspaceId: persistedWorkspaceId,
            stableId: UUID(),
            reservedWorkspaceIds: &reservedWorkspaceIds
        )

        #expect(restoredWorkspaceId == persistedWorkspaceId)
        #expect(reservedWorkspaceIds == [persistedWorkspaceId])
    }

    @Test("mints a fresh id when the persisted workspace id is already reserved")
    func mintsFreshIdForDuplicatePersistedWorkspaceId() {
        let identitySelector = WorkspaceSessionRestoreIdentity()
        let persistedWorkspaceId = UUID()
        var reservedWorkspaceIds: Set<UUID> = [persistedWorkspaceId]

        let restoredWorkspaceId = identitySelector.restoredWorkspaceId(
            persistedWorkspaceId: persistedWorkspaceId,
            stableId: UUID(),
            reservedWorkspaceIds: &reservedWorkspaceIds
        )

        #expect(restoredWorkspaceId != persistedWorkspaceId)
        #expect(reservedWorkspaceIds.contains(persistedWorkspaceId))
        #expect(reservedWorkspaceIds.contains(restoredWorkspaceId))
        #expect(reservedWorkspaceIds.count == 2)
    }

    @Test("mints a fresh id when the stable identity is excluded")
    func mintsFreshIdForExcludedStableIdentity() {
        let identitySelector = WorkspaceSessionRestoreIdentity()
        let persistedWorkspaceId = UUID()
        let stableId = UUID()
        var reservedWorkspaceIds: Set<UUID> = []

        let restoredWorkspaceId = identitySelector.restoredWorkspaceId(
            persistedWorkspaceId: persistedWorkspaceId,
            stableId: stableId,
            reservedWorkspaceIds: &reservedWorkspaceIds,
            excludingStableIdentities: [stableId]
        )

        #expect(restoredWorkspaceId != persistedWorkspaceId)
        #expect(reservedWorkspaceIds == [restoredWorkspaceId])
    }
}
