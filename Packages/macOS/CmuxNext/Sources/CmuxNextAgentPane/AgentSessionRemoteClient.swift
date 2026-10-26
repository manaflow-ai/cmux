public import Foundation

/// The owning session daemon's side of a chat on another machine (`agent-session-attach-v1`,
/// cmux-tui/spec/commands.md "Agent session attach"): typed calls on ONE store tab. The daemon
/// pins the acpmux session from its own record, so nothing here names a session, a folder or a
/// command. JSON values travel as `Data` (the daemon's own JSON).
public nonisolated protocol AgentSessionRemoteClient: Sendable {
    /// True when this wire observes a session without permission to prompt, cancel or answer it.
    var isReadOnly: Bool { get }
    /// Subscribes and returns acpmux's attach page `{session, events, hasMore, lastSeq}`.
    /// Events then go to `handler` until ``detach()``, ``close()`` or a `.closed` event.
    func attach(_ page: AgentSessionPage, events handler: @escaping @Sendable (AgentSessionRemoteEvent) -> Void) async throws -> Data
    /// A page of the attached session's log (`{events, hasMore, lastSeq}`).
    func events(_ page: AgentSessionPage) async throws -> Data
    /// Sends one text prompt; answers `{prompt_id, turn_id, queued}` once acpmux recorded it.
    func prompt(id: String, text: String) async throws -> Data
    func cancel() async throws
    /// Answers a permission request the daemon announced on this attachment, with the person's
    /// decision proof of a relayed allow when the pane made one (cx-0q7o; acpmux decides).
    func permission(id: String, option: String, decisionNonce: String?, personDecision: String?) async throws
    func detach() async
    /// Ends the attachment and its daemon connection.
    func close() async
    /// The chats the attached session started on that machine, as its acpmux summarizes them
    /// (`{sessions}`, `agent-session-children-v1`); their changes then arrive as `.changed`.
    func children() async throws -> Data
    /// Reads one image from the attached chat's host, as `{mimeType, data}` with base64 bytes.
    func media(path: String) async throws -> Data
    /// The person starts or stops typing in the chat (`agent-session-presence-v1`).
    func typing(_ on: Bool) async throws
    /// Whether the person's window shows the chat now (`agent-session-presence-v1`).
    func view(_ visible: Bool) async throws
}

extension AgentSessionRemoteClient {
    /// A daemon without `agent-session-children-v1` lists none.
    public func children() async throws -> Data { Data(#"{"sessions":[]}"#.utf8) }
    /// A daemon without `agent-session-presence-v1` shows no one: typing and view go nowhere.
    public func typing(_ on: Bool) async throws {}
    public func view(_ visible: Bool) async throws {}
    /// Older daemons have no host media command; callers turn this into a refused image.
    public func media(path: String) async throws -> Data {
        throw AgentSessionRemoteError(code: "agent_session.media_unsupported", message: "the daemon does not serve agent session media")
    }
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
    /// Who is in the chat now (`_acpmux/presence` params, the whole set on every change).
    case presence(Data)
    /// The attachment ended (`lagged`, `overflow`, `acpmux_closed`, `detached`, or the daemon
    /// connection dropped); the page reconnects and replays from the newest seq it holds.
    case closed(String)
}
