public import CmuxNextAgentActivity

/// A chat on an acpmux peer (huge-blue, cmux16…) as this Mac's daemon mirrors it. A tab never binds
/// to another machine's daemon (cx-k21v); it binds to the mirrored session on this Mac's acpmux,
/// which forwards to the peer, as the sidebar's machine groups and the Priority view open one. So
/// `agent.openSessionTab {session, host: "<peer>"}` opens the mirrored session with no host.
public enum AgentPeerSession: Equatable {
    /// The mirrored session's id on this Mac's acpmux.
    case session(String)
    /// The host is a peer this Mac mirrors, but it has no live chat by that name.
    case unknownSession
    /// More than one live chat of the host has that name (acpmux names can repeat): name it by id.
    case ambiguous
    /// The host is no peer this Mac mirrors.
    case notAPeer
}

extension Collection<AgentActivityLane> {
    /// What `session` on peer `host` names among these lanes. `session` may be the session id, the
    /// qualified id (`<peer>/<id>`), the acpmux name (`<peer>/<name>`) or the bare name. An id
    /// wins; a name must name one chat.
    public func peerSession(_ session: String, on host: String) -> AgentPeerSession {
        let mirrored = filter { $0.peer == host }
        guard !mirrored.isEmpty else { return .notAPeer }
        let bare = session.hasPrefix(host + "/") ? String(session.dropFirst(host.count + 1)) : session
        if let byID = mirrored.first(where: { $0.id == bare }) { return .session(byID.id) }
        let named = mirrored.filter { $0.name == host + "/" + bare }
        switch named.count {
        case 0: return .unknownSession
        case 1: return .session(named[0].id)
        default: return .ambiguous
        }
    }
}

/// What an agent's `session` names among this Mac's own chats (`agent.openSessionTab`,
/// `agent.openSessionWorkspace`). A tab records the id it is opened with, and the chat pane finds
/// its chat by acpmux's id: a tab opened with the chat's name or its harness's own session id
/// (`acpmux ls --json` prints `agentSessionId` first) waited on "Reconnecting…" forever for a
/// session no machine lists (Leo, 2026-11-05). So the open resolves it to acpmux's id first.
public enum AgentLocalSession: Equatable {
    /// acpmux's id of the one chat `session` names (the id itself when it is one).
    case session(String)
    /// Nothing live here goes by it: opened as given (a chat that just started, a fixed-id or
    /// mirrored peer id, or one acpmux keeps without a lane); the chat pane resolves a name it
    /// lists later.
    case asGiven
    /// More than one live chat here goes by it: name it by its session id.
    case ambiguous
}

extension Collection<AgentActivityLane> {
    /// What `session` names among this Mac's live chats (lanes with no peer): acpmux's id wins, then
    /// the harness's session id (`agentSession`), the acpmux name or its short name, which must
    /// name one chat. Any lane's own id (a peer's mirrored one too) and text nothing goes by are
    /// opened as given.
    public func localSession(_ session: String) -> AgentLocalSession {
        if contains(where: { $0.id == session }) { return .session(session) }
        let named = filter { $0.peer == nil && ($0.agentSession == session || $0.name == session || $0.shortName == session) }
        switch named.count {
        case 0: return .asGiven
        case 1: return .session(named[0].id)
        default: return .ambiguous
        }
    }
}
