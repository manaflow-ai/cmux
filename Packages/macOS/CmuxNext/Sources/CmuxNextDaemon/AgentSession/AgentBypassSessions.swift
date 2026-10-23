import CmuxNextCompat
public import Foundation

/// The agent chats of other machines that run in a mode that does not ask before acting, by
/// session id, for observers: each workspace row that shows one carries the bypass warning
/// (`SidebarMapping`). Filled from what the chat's daemon says, never from what the app did: the
/// adopt answer, each attach reply (`agentMode`), the attachment's `agent-session-mode` pushes
/// and one `agent-session-mode` read per bound tab at each connect (`DaemonService`), so a
/// relaunch, a mode change or a chat an agent adopted there all show.
@MainActor
public final class AgentBypassSessions {
    public static let shared = AgentBypassSessions()
    private let sessions = ObservedMap<String, Bool>()

    public init() {}

    public func set(_ session: String, bypass: Bool) { sessions.set(bypass ? true : nil, forKey: session) }

    /// Observes `session` only.
    public func contains(_ session: String) -> Bool { sessions[session] ?? false }

    /// Where a line carries a daemon's mode facts (`{session, mode, asking}`).
    public enum Carrier: Sendable {
        /// The `agent-session-mode` answer: the object itself.
        case answer
        /// An `agent-session-mode` push: its `mode`.
        case push
        /// An attach reply: its `agentMode`.
        case attachReply
    }

    /// Records the mode facts `carrier` holds in `line`, from any isolation, on the next main
    /// turn. Facts without `asking` never read as asking; a line without facts changes nothing.
    public nonisolated static func note(_ carrier: Carrier, of line: Data) {
        let decoder = JSONDecoder()
        let facts: Facts? = switch carrier {
        case .answer: try? decoder.decode(Facts.self, from: line)
        case .push: (try? decoder.decode(Pushed.self, from: line))?.mode
        case .attachReply: (try? decoder.decode(Attached.self, from: line))?.agentMode
        }
        guard let facts, !facts.session.isEmpty else { return }
        // task-owner: one main-actor hop that sets one map entry and ends; nothing to cancel
        Task { @MainActor in shared.set(facts.session, bypass: !(facts.asking ?? false)) }
    }

    private struct Facts: Decodable {
        let session: String
        let asking: Bool?
    }

    private struct Pushed: Decodable { let mode: Facts? }

    private struct Attached: Decodable { let agentMode: Facts? }
}
