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
        /// `host` is no peer this Mac mirrors.
        case notAPeer
    }

    /// `session` may be the session id, the qualified id (`<peer>/<id>`), the acpmux name
    /// (`<peer>/<name>`) or the bare name.
    public static func resolve(_ session: String, peer host: String, lanes: some Collection<AgentActivityLane>) -> Match {
        let mirrored = lanes.filter { $0.peer == host }
        guard !mirrored.isEmpty else { return .notAPeer }
        let bare = session.hasPrefix(host + "/") ? String(session.dropFirst(host.count + 1)) : session
        let match = mirrored.first { $0.id == bare } ?? mirrored.first { $0.name == host + "/" + bare || $0.name == bare }
        return match.map { .session($0.id) } ?? .unknownSession
    }
}
