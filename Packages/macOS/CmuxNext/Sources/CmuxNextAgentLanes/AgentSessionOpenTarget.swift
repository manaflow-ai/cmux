public import CmuxNextActions
public import CmuxNextAgentActivity
import CmuxNextHomeEngine
import Foundation

/// Why `agent.openSessionTab` / `agent.openSessionWorkspace` open no tab for the `session` they were
/// given; its description is the refusal the caller reads (the App throws it as an `ActionFailure`).
public struct AgentSessionOpenRefusal: Error, Equatable, CustomStringConvertible {
    public let description: String

    /// More than one live chat here goes by `session` (its name or harness session id).
    static func ambiguousLocal(_ session: String) -> Self {
        Self(description: String(format: String(localized: "handlers.misc.failed.ambiguousLocalSession",
                                                 defaultValue: "More than one chat here is named %@. Name it by its session id.", bundle: .localizedModule), session))
    }

    /// `peer` is a host this Mac mirrors, but no live chat of it is named `session`.
    static func noPeerSession(_ session: String, _ peer: String) -> Self {
        Self(description: String(format: String(localized: "handlers.misc.failed.noPeerSession",
                                                 defaultValue: "%1$@ has no running chat named %2$@.", bundle: .localizedModule), peer, session))
    }

    /// More than one live chat of `peer` has the name `session`.
    static func ambiguousPeerSession(_ session: String, _ peer: String) -> Self {
        Self(description: String(format: String(localized: "handlers.misc.failed.ambiguousPeerSession",
                                                 defaultValue: "%1$@ has more than one chat named %2$@. Name it by its session id.", bundle: .localizedModule),
                                 peer, session))
    }
}

extension AgentLaneStore {
    /// acpmux's id of the chat `session` names on this Mac (``AgentLocalSession``), so a tab never
    /// records a chat's name or its harness's session id, which the chat pane cannot find
    /// ("Reconnecting…" forever, Leo 2026-11-05). Only for this Mac's own chats (`host` absent or
    /// `localHost`) and only once the lane watch has every session (``live``); otherwise `session`
    /// as given. `agent.openSessionWorkspace` opens this.
    public func localSessionID(_ session: String, host: String?, localHost: String?) throws(AgentSessionOpenRefusal) -> String {
        guard host == nil || host == localHost, live else { return session }
        switch lanes.values.localSession(session) {
        case .session(let id): return id
        case .asGiven: return session
        case .ambiguous: throw AgentSessionOpenRefusal.ambiguousLocal(session)
        }
    }

    /// Reads the arguments of a tab-open action and resolves its chat before the app changes focus.
    public func tabSession(for invocation: ActionInvocation, localHost: String?, sessionRequired: @autoclosure () -> String) throws(AgentSessionOpenRefusal) -> (session: String, host: String?) {
        let session = (invocation["session"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty else { throw AgentSessionOpenRefusal(description: sessionRequired()) }
        let host = invocation["host"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        return try tabSession(session, host: host, localHost: localHost)
    }

    /// The session and host `agent.openSessionTab` binds its tab to: this Mac's chat by acpmux's id
    /// (``localSessionID(_:host:localHost:)``), and a peer's chat as the session this Mac's acpmux
    /// mirrors, with no host (``AgentPeerSession``: the tab binds here, never there). A Chief home's
    /// host (`chief:<home id>`) and a host that is no peer stay as given; the tab's host check
    /// refuses the latter with its own reason.
    public func tabSession(_ session: String, host: String?, localHost: String?) throws(AgentSessionOpenRefusal) -> (session: String, host: String?) {
        let session = try localSessionID(session, host: host, localHost: localHost)
        guard let peer = host, !peer.hasPrefix(ChiefHome.tabHostPrefix), peer != localHost else { return (session, host) }
        switch lanes.values.peerSession(session, on: peer) {
        case .session(let mirrored): return (mirrored, nil)
        case .unknownSession: throw AgentSessionOpenRefusal.noPeerSession(session, peer)
        case .ambiguous: throw AgentSessionOpenRefusal.ambiguousPeerSession(session, peer)
        case .notAPeer: return (session, host)
        }
    }
}
