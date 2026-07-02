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
    private var removedVersionBySessionID: [String: Int] = [:]

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
    public mutating func applying(
        _ frame: ChatSessionEventFrame,
        to sessions: [ChatSessionDescriptor]
    ) -> [ChatSessionDescriptor] {
        switch frame.event {
        case .descriptorChanged(let descriptor):
            if let removedVersion = removedVersionBySessionID[descriptor.id],
               descriptor.version <= removedVersion {
                return sessions
            }
            // Out-of-workspace descriptors never enter a scoped list.
            if let workspaceID, descriptor.workspaceID != workspaceID {
                return sessions
            }
            var updated = sessions
            if let index = updated.firstIndex(where: { $0.id == descriptor.id }) {
                // Version-gated upsert: best-effort pushes can arrive out of
                // order, be duplicated, or race an authoritative pull. The host
                // stamps a strictly increasing `version` on every change, so a
                // descriptor whose version is LOWER than the one already
                // applied is stale (or out of order) and must not clobber newer
                // state the client got from a later push or a snapshot pull.
                // Equal version is allowed through (a no-op in practice: the
                // monotonic counter guarantees equal version == identical
                // content), which also keeps unversioned (version 0) payloads
                // upserting as before.
                guard descriptor.version >= updated[index].version else {
                    return sessions
                }
                updated[index] = descriptor
            } else {
                updated.append(descriptor)
            }
            removedVersionBySessionID.removeValue(forKey: descriptor.id)
            return updated
        case .stateChanged:
            // The bare state push carries NO version, so applying it here would
            // let a duplicated or reordered frame clobber newer state the list
            // already holds (the host emits an unversioned `stateChanged` AND a
            // versioned `descriptorChanged` for the SAME transition, so the list
            // always gets the state through the version-gated descriptor path
            // above). The list is therefore driven solely by `descriptorChanged`;
            // the unversioned `stateChanged` is a no-op for the list. The focused
            // conversation's `ChatConversationStore` still consumes `stateChanged`
            // directly for its own live state (it is not version-reconciled).
            return sessions
        case .sessionRemoved(let version):
            let currentVersion = sessions.first { $0.id == frame.sessionID }?.version ?? 0
            guard version >= currentVersion else { return sessions }
            if version != Int.max {
                removedVersionBySessionID[frame.sessionID] = max(
                    removedVersionBySessionID[frame.sessionID] ?? 0,
                    version
                )
            }
            return sessions.filter { $0.id != frame.sessionID }
        case .appended, .updated, .terminalBlocks, .streamingProse, .reset, .unknown:
            // Transcript-content frames don't affect the session list.
            return sessions
        }
    }
}
