import Foundation

/// A chat event source that can discover and reconcile the host's sessions.
///
/// ``ChatEventSource`` is intentionally scoped to one conversation so it can
/// be used by transcript and artifact consumers. A session browser needs a
/// small additional surface for the authoritative list and snapshots, plus a
/// best-effort stream of frames for every session. Keeping those operations in
/// a refinement lets UI models depend on one transport-agnostic protocol while
/// preserving the narrower source seam for existing consumers.
public protocol AgentChatSessionSource: ChatEventSource, Sendable {
    /// Lists the sessions known by the host, optionally scoped to a workspace.
    func sessions(workspaceID: String?) async throws -> [ChatSessionDescriptor]

    /// Pulls the authoritative current descriptor for one session.
    func session(sessionID: String) async throws -> ChatSessionDescriptor

    /// Opens the host-wide best-effort stream of session event frames.
    ///
    /// The stream finishes when the underlying connection closes. Consumers
    /// should re-list or pull snapshots when reconnecting or repairing gaps.
    func sessionEvents() async -> AsyncStream<ChatSessionEventFrame>
}
