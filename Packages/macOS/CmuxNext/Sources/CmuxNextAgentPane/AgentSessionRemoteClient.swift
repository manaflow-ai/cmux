public import Foundation

/// The owning session daemon's side of a chat on another machine (`agent-session-attach-v1`,
/// cmux-tui/spec/commands.md "Agent session attach"): typed calls on ONE store tab. The daemon
/// pins the acpmux session from its own record, so nothing here names a session, a folder or a
/// command. JSON values travel as `Data` (the daemon's own JSON).
public nonisolated protocol AgentSessionRemoteClient: Sendable {
    /// Subscribes and returns acpmux's attach page `{session, events, hasMore, lastSeq}`.
    /// Events then go to `handler` until ``detach()``, ``close()`` or a `.closed` event.
    func attach(_ page: AgentSessionPage, events handler: @escaping @Sendable (AgentSessionRemoteEvent) -> Void) async throws -> Data
    /// A page of the attached session's log (`{events, hasMore, lastSeq}`).
    func events(_ page: AgentSessionPage) async throws -> Data
    /// Sends one text prompt; answers `{prompt_id, turn_id, queued}` once acpmux recorded it.
    func prompt(id: String, text: String) async throws -> Data
    func cancel() async throws
    /// Answers a permission request the daemon announced on this attachment.
    func permission(id: String, option: String) async throws
    func detach() async
    /// Ends the attachment and its daemon connection.
    func close() async
}

/// A page request: forward from `afterSeq`, or the newest `limit` before `beforeSeq`.
public nonisolated struct AgentSessionPage: Sendable, Equatable {
    public var afterSeq: UInt64?
    public var beforeSeq: UInt64?
    public var limit: Int?
    public var kinds: [String]?

    public init(afterSeq: UInt64? = nil, beforeSeq: UInt64? = nil, limit: Int? = nil, kinds: [String]? = nil) {
        self.afterSeq = afterSeq
        self.beforeSeq = beforeSeq
        self.limit = limit
        self.kinds = kinds
    }
}

/// What the daemon pushes for an attachment.
public nonisolated enum AgentSessionRemoteEvent: Sendable, Equatable {
    /// One acpmux record (`eventStream` form).
    case record(Data)
    /// A permission request acpmux announced (`_acpmux/permission_pending` params).
    case permission(Data)
    /// The session's status or queue changed (`_acpmux/session_changed` params).
    case changed(Data)
    /// The attachment ended (`lagged`, `overflow`, `acpmux_closed`, `detached`, or the daemon
    /// connection dropped); the page reconnects and replays from the newest seq it holds.
    case closed(String)
}
