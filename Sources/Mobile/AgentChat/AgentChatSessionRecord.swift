import CmuxAgentChat
import Foundation

/// One chat-capable agent session the Mac knows about: hook-derived
/// identity, terminal binding, transcript location, and live state.
struct AgentChatSessionRecord: Sendable {
    /// The agent's own session identifier (hook `session_id`, unprefixed).
    let sessionID: String

    /// Which agent runtime owns the session.
    let agentKind: ChatAgentKind

    /// Owning cmux workspace UUID string, when known.
    var workspaceID: String?

    /// Hosting cmux terminal surface UUID string, when known. Required for
    /// the send/interrupt path.
    var surfaceID: String?

    /// The session's working directory, when known.
    var workingDirectory: String?

    /// Absolute transcript JSONL path, when resolved.
    var transcriptPath: String?

    /// Live activity state derived from hook events.
    var state: ChatAgentState

    /// Timestamp of the most recent hook or transcript activity.
    var lastActivityAt: Date

    /// Conversation title (first user prompt), filled by the tailer.
    var title: String?

    /// The agent process id, for liveness sweeps.
    var pid: Int?

    /// Real hook-store key, when this record is surfaced under a pending alias.
    var hookStoreSessionID: String?

    /// Monotonic revision stamped by the registry on every change, so clients
    /// can reconcile best-effort pushes against authoritative pulls. Owned by
    /// the registry; mutators do not set it directly.
    var version: Int = 0

    var hookStoreLookupSessionID: String { hookStoreSessionID ?? sessionID }

    mutating func rememberHookStoreSessionID(_ id: String) {
        if id != sessionID { hookStoreSessionID = id }
    }

    /// Adopts terminal/transcript bindings from a hook-store entry. The
    /// store is rewritten by every hook event, so its non-nil fields are
    /// fresher than the record's (panel UUIDs change across app
    /// relaunches; never keep a stale binding over a present one).
    ///
    /// - Parameter entry: The store entry to adopt from.
    /// - Parameters:
    ///   - entry: The store entry to adopt from.
    ///   - includingPID: Whether to adopt the process id. Failure-driven
    ///     refreshes pass `false`: the store can lag a SessionStart by one
    ///     write, and adopting a dead pid there would let the liveness
    ///     sweep end a live resumed session.
    mutating func adoptBindings(
        from entry: AgentChatHookSessionStore.Entry,
        includingPID: Bool = true
    ) {
        rememberHookStoreSessionID(entry.sessionID)
        surfaceID = entry.surfaceID ?? surfaceID
        workspaceID = entry.workspaceID ?? workspaceID
        transcriptPath = entry.transcriptPath ?? transcriptPath
        workingDirectory = entry.workingDirectory ?? workingDirectory
        if includingPID {
            pid = entry.pid ?? pid
        }
    }

    /// The wire descriptor for this record.
    var descriptor: ChatSessionDescriptor {
        ChatSessionDescriptor(
            id: sessionID,
            agentKind: agentKind,
            title: title,
            workspaceID: workspaceID,
            terminalID: surfaceID,
            workingDirectory: workingDirectory,
            state: state,
            lastActivityAt: lastActivityAt,
            version: version
        )
    }
}
