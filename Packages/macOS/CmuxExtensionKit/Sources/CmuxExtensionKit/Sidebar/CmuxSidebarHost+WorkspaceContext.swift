import Foundation

extension CmuxSidebarHost {
    /// Applies one manual context edit to the exact workspace and revision.
    /// - Parameters:
    ///   - workspaceID: Workspace identity from the latest snapshot.
    ///   - expectedRevision: Revision read from that workspace's context.
    ///   - mutation: Deliberate accepted metadata edit.
    /// - Throws: ``CmuxSidebarActionError`` on conflict, rejection, or cancellation.
    public func mutateWorkspaceContext(workspaceID: UUID, expectedRevision: UInt64, mutation: CmuxSidebarWorkspaceContextMutation) async throws {
        try await send(.mutateWorkspaceContext(workspaceID: workspaceID, expectedRevision: expectedRevision, mutation: mutation))
    }

    /// Persists an analysis proposal without changing accepted tags, summary, or title.
    /// - Parameters:
    ///   - workspaceID: Exact target workspace.
    ///   - expectedRevision: Current native context revision.
    ///   - proposal: Analysis with exact source fingerprint and conversation IDs.
    /// - Throws: ``CmuxSidebarActionError`` on conflict, rejection, or cancellation.
    public func storeWorkspaceContextProposal(workspaceID: UUID, expectedRevision: UInt64, proposal: CmuxSidebarWorkspaceContextProposal) async throws {
        try await send(.storeWorkspaceContextProposal(workspaceID: workspaceID, expectedRevision: expectedRevision, proposal: proposal))
    }

    /// Accepts selected fields of the currently retained proposal.
    /// Manual tag dimensions and rejected automatic IDs remain protected.
    /// Accepting a title additionally requires the renameWorkspace permission.
    /// - Parameters:
    ///   - workspaceID: Exact target workspace.
    ///   - expectedRevision: Current native context revision.
    ///   - proposalID: Identity of the retained analysis.
    ///   - tagIDs: Exact proposed tag IDs the user accepts.
    ///   - acceptTitle: Whether the user also accepts the proposed title.
    ///   - acceptSummary: Whether the user accepts the proposed summary.
    /// - Throws: ``CmuxSidebarActionError`` on conflict, rejection, or cancellation.
    public func applyWorkspaceContextProposal(workspaceID: UUID, expectedRevision: UInt64, proposalID: UUID, tagIDs: [String], acceptTitle: Bool = false, acceptSummary: Bool = false) async throws {
        try await send(.applyWorkspaceContextProposal(workspaceID: workspaceID, expectedRevision: expectedRevision, proposalID: proposalID, tagIDs: tagIDs, acceptTitle: acceptTitle, acceptSummary: acceptSummary))
    }

    /// Undoes the latest native context edit without rewinding its revision.
    /// Any title changed by that edit is restored only if it still matches the applied title.
    /// Requires renameWorkspace because a previous edit may have changed the title.
    /// - Parameters:
    ///   - workspaceID: Exact target workspace.
    ///   - expectedRevision: Current native context revision.
    /// - Throws: ``CmuxSidebarActionError`` on conflict, rejection, or cancellation.
    public func undoWorkspaceContext(workspaceID: UUID, expectedRevision: UInt64) async throws {
        try await send(.undoWorkspaceContext(workspaceID: workspaceID, expectedRevision: expectedRevision))
    }
}
