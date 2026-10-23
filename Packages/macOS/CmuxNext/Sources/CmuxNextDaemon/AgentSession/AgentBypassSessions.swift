import CmuxNextCompat
public import Foundation

/// The agent chats of other machines that run in a mode that does not ask before acting, by the
/// tab's host (`registry:<id>`, the machine's store) and session (two machines may each run a
/// chat of the same id or name), for observers: each workspace row that shows one carries the bypass warning
/// (`SidebarMapping`). Filled from what the chat's daemon says, never from what the app did: the
/// adopt answer, each attach reply (`agentMode`), the attachment's `agent-session-mode` pushes
/// and one `agent-session-mode` read per bound tab at each connect (`DaemonService`), so a
/// relaunch, a mode change or a chat an agent adopted there all show.
@MainActor
public final class AgentBypassSessions {
    // singleton-allow: the facts are process-wide by nature (a session id's mode, as any machine's daemon reports it): every attach client of every machine, the per-daemon mode reads and the adopt write them from many isolations, and every window's static SidebarMapping row mapping (no injection path) must read the same map, or one window would hide a bypass warning another shows.
    public static let shared = AgentBypassSessions()
    private let sessions = ObservedMap<Key, Bool>()

    public init() {}

    /// A chat as an agent tab's record names it: its host and its session.
    struct Key: Hashable, Sendable {
        let host: String
        let session: String
    }

    public func set(_ session: String, host: String, bypass: Bool) {
        sessions.set(bypass ? true : nil, forKey: Key(host: host, session: session))
    }

    /// Observes `session` of `host` only.
    public func contains(_ session: String, host: String) -> Bool { sessions[Key(host: host, session: session)] ?? false }

    /// Where a line carries a daemon's mode facts (`{session, mode, asking}`).
    public enum Carrier: Sendable {
        /// The `agent-session-mode` answer: the object itself.
        case answer
        /// An `agent-session-mode` push: its `mode`.
        case push
        /// An attach reply: its `agentMode`.
        case attachReply
    }

    /// Records the mode facts `carrier` holds in `line` for a chat of `host` (the daemon's tab
    /// host, `registry:<id>`), from any isolation, on the next main turn. Facts without `asking`
    /// never read as asking; a line without facts, or no host, changes nothing.
    public nonisolated static func note(_ carrier: Carrier, of line: Data, host: String?) {
        guard let host else { return }
        let decoder = JSONDecoder()
        let facts: Facts? = switch carrier {
        case .answer: try? decoder.decode(Facts.self, from: line)
        case .push: (try? decoder.decode(Pushed.self, from: line))?.mode
        case .attachReply: (try? decoder.decode(Attached.self, from: line))?.agentMode
        }
        guard let facts, !facts.session.isEmpty else { return }
        // task-owner: one main-actor hop that sets one map entry and ends; nothing to cancel
        Task { @MainActor in shared.set(facts.session, host: host, bypass: !(facts.asking ?? false)) }
    }

    private struct Facts: Decodable {
        let session: String
        let asking: Bool?
    }

    private struct Pushed: Decodable { let mode: Facts? }

    private struct Attached: Decodable { let agentMode: Facts? }
}
