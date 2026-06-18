/// Folds the host's live `chat.message` push frames into a workspace's
/// chat-session list, so the session list (and the GUI toggle that depends
/// on it) stays current without polling.
///
/// The host pushes one ``ChatSessionEventFrame`` whenever a session's
/// descriptor or live state changes, including the first time a session
/// appears (a brand-new agent emits `descriptorChanged` with `previous`
/// nil). A consumer seeds the list once from `mobile.chat.sessions`, then
/// applies each subsequent frame through this reducer; because every fold is
/// an idempotent upsert, a frame that races the seed converges either way.
public struct ChatSessionListReducer: Sendable {
    /// The workspace whose sessions the list holds. A `descriptorChanged`
    /// for a different workspace is ignored; `nil` accepts every workspace.
    public let workspaceID: String?

    /// Creates a reducer scoped to one workspace.
    ///
    /// - Parameter workspaceID: The workspace to keep, or `nil` for all.
    public init(workspaceID: String?) {
        self.workspaceID = workspaceID
    }

    /// Applies one push frame to the current session list.
    ///
    /// - Parameters:
    ///   - frame: The pushed session event.
    ///   - sessions: The current list.
    /// - Returns: The updated list (unchanged for irrelevant frames).
    public func applying(
        _ frame: ChatSessionEventFrame,
        to sessions: [ChatSessionDescriptor]
    ) -> [ChatSessionDescriptor] {
        switch frame.event {
        case .descriptorChanged(let descriptor):
            // Out-of-workspace descriptors never enter a scoped list.
            if let workspaceID, descriptor.workspaceID != workspaceID {
                return sessions
            }
            var updated = sessions
            if let index = updated.firstIndex(where: { $0.id == descriptor.id }) {
                updated[index] = descriptor
            } else {
                updated.append(descriptor)
            }
            return updated
        case .stateChanged(let state):
            // A state push carries no workspace; only ever update an entry
            // already in the (workspace-scoped) list, never insert.
            guard let index = sessions.firstIndex(where: { $0.id == frame.sessionID }) else {
                return sessions
            }
            var updated = sessions
            updated[index] = updated[index].withState(state)
            return updated
        case .appended, .updated, .terminalBlocks, .reset, .unknown:
            // Transcript-content frames don't affect the session list.
            return sessions
        }
    }
}
