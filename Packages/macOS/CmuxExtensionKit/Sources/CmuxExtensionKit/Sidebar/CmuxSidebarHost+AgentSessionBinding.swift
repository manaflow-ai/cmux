import Foundation

extension CmuxSidebarHost {
    /// Binds an explicitly supplied session to the process shown by a native snapshot.
    ///
    /// This changes identity metadata, never activity. The host rejects stale generations,
    /// ambiguous processes, unsupported tools, and missing live ownership.
    /// - Parameters:
    ///   - workspaceID: Current native workspace identity.
    ///   - surfaceID: Current native surface identity.
    ///   - toolID: Native tool identifier from its runtime observation.
    ///   - sessionID: Exact session identifier supplied by the user.
    ///   - expectedProcessGeneration: Process generation captured before requesting the binding.
    /// - Throws: ``CmuxSidebarActionError`` if the host cannot prove the binding.
    public func bindAgentSession(workspaceID: UUID, surfaceID: UUID, toolID: String, sessionID: String, expectedProcessGeneration: UInt64) async throws {
        try await send(.bindAgentSession(workspaceID: workspaceID, surfaceID: surfaceID, toolID: toolID, sessionID: sessionID, expectedProcessGeneration: expectedProcessGeneration))
    }
}
