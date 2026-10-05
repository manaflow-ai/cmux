public import Foundation
import Synchronization

/// The sessions this pane started or shows (b, ad349): `_acpmux/kill`, `permission_respond` and
/// `permission_group_respond` are allowed only for them. A session is the pane's when it came back
/// from the pane's own `session/new`, `acp.session.fork` or `_acpmux/handoff_start` (their replies
/// are read off the main thread), when the user opened it in this pane by a gesture (an attach made
/// with one, a click in the session list), or when the host itself opened the tab on it (restore,
/// a session link). An attach alone adds nothing; attach and watch stay open.
public nonisolated final class AcpmuxPaneSessions: Sendable {
    /// The requests whose reply names a session the pane started.
    public static let starting: Set<String> = ["session/new", "acp.session.fork", "_acpmux/handoff_start"]

    private struct State {
        var sessions: Set<String> = []
        /// Raw JSON-RPC ids of the starting requests still waiting for their reply.
        var awaiting: Set<String> = []
    }

    private let state = Mutex(State())

    public init() {}

    public func add(_ session: String) { state.withLock { _ = $0.sessions.insert(session) } }

    public func contains(_ session: String) -> Bool { state.withLock { $0.sessions.contains(session) } }

    /// The pane sent `method` with `params` and raw id `id`: track what it starts or shows.
    func sent(method: String, id: String?, params: [String: Any]) {
        if Self.starting.contains(method), let id { state.withLock { _ = $0.awaiting.insert(id) } }
    }

    /// A daemon frame: when it answers a starting request, its sessions are the pane's.
    public func observe(_ text: String) {
        guard state.withLock({ !$0.awaiting.isEmpty }), text.contains("\"result\""),
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let id = object["id"].flatMap(AcpmuxPaneMethods.rawID) else { return }
        let result = object["result"] as? [String: Any] ?? [:]
        let named = ["sessionId", "targetSessionId"].compactMap { result[$0] as? String }
        state.withLock { state in
            guard state.awaiting.remove(id) != nil else { return }
            state.sessions.formUnion(named)
        }
    }
}
