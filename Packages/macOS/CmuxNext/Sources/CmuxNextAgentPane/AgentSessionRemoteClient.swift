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
    /// Answers a permission request the daemon announced on this attachment, with a question's
    /// `answers` and `annotations` (JSON) and the person's decision proof of a relayed allow when
    /// the pane made one (cx-0q7o; acpmux decides, and an answer's proof covers both).
    func permission(id: String, option: String, answers: Data?, annotations: Data?, decisionNonce: String?,
                    personDecision: String?) async throws
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
    /// The person's model, mode and option picks for the chat (`agent-session-settings-v1`):
    /// acpmux's `session/set_model`, `session/set_mode` and `session/set_config_option` on that
    /// machine, answered as acpmux answers them (a config option answers `{configOptions}`).
    func setModel(_ modelId: String) async throws -> Data
    func setMode(_ modeId: String) async throws -> Data
    func setConfig(id configId: String, value: String) async throws -> Data
    /// Whether that machine's daemon relays a Cloud chat's own sign-in (`agent-session-login-v1`).
    func servesLogin() async -> Bool
    /// One step of the chat's agent's own sign-in on that machine (`agent-session-login-v1`):
    /// acpmux's `_acpmux/agent_login/<op>` answer, or `{refused: {reason}}`. `fields` are the
    /// daemon's (`agent`, `login_id`, `code`, `key`); the code and key are never logged.
    func login(_ op: String, _ fields: [String: String]) async throws -> Data
}

extension AgentSessionRemoteClient {
    /// A daemon without `agent-session-children-v1` lists none.
    public func children() async throws -> Data { Data(#"{"sessions":[]}"#.utf8) }
    /// A daemon without `agent-session-presence-v1` shows no one: typing and view go nowhere.
    public func typing(_ on: Bool) async throws {}
    public func view(_ visible: Bool) async throws {}
    /// A daemon without `agent-session-settings-v1` changes nothing: the pick says so.
    public func setModel(_ modelId: String) async throws -> Data { throw Self.settingsUnsupported }
    public func setMode(_ modeId: String) async throws -> Data { throw Self.settingsUnsupported }
    public func setConfig(id configId: String, value: String) async throws -> Data { throw Self.settingsUnsupported }
    nonisolated static var settingsUnsupported: AgentSessionRemoteError {
        AgentSessionRemoteError(code: "agent_session.settings_unsupported",
                                message: "update cmux on that machine to change this chat's model, mode or options from here")
    }
    /// A daemon without `agent-session-login-v1` offers no sign-in.
    public func servesLogin() async -> Bool { false }
    public func login(_ op: String, _ fields: [String: String]) async throws -> Data {
        Data(#"{"refused":{"reason":"unsupported"}}"#.utf8)
    }
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
