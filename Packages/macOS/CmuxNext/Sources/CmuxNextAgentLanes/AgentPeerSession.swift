public import CmuxNextAgentActivity

/// A chat on an acpmux peer (huge-blue, cmux16…) as this Mac's daemon mirrors it. A tab never binds
/// to another machine's daemon (cx-k21v); it binds to the mirrored session on this Mac's acpmux,
/// which forwards to the peer, as the sidebar's machine groups and the Priority view open one. So
/// `agent.openSessionTab {session, host: "<peer>"}` opens the mirrored session with no host.
public enum AgentPeerSession {
    /// What `session` on peer `host` names among `lanes`.
    public enum Match: Equatable {
        /// The mirrored session's id on this Mac's acpmux.
        case session(String)
        /// `host` is a peer this Mac mirrors, but it has no live chat named `session`.
        case unknownSession
        /// More than one live chat of `host` has that name (acpmux names can repeat): name it by id.
        case ambiguous
        /// `host` is no peer this Mac mirrors.
        case notAPeer
    }

    /// `session` may be the session id, the qualified id (`<peer>/<id>`), the acpmux name
    /// (`<peer>/<name>`) or the bare name. An id wins; a name must name one chat.
    public static func resolve(_ session: String, peer host: String, lanes: some Collection<AgentActivityLane>) -> Match {
        let mirrored = lanes.filter { $0.peer == host }
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
