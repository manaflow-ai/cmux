public import Foundation
import Synchronization

/// The sessions this pane started or shows (b, ad349): `_acpmux/kill`, `permission_respond` and
/// `permission_group_respond` are allowed only for them. A session is the pane's when it came back
/// from the pane's own `session/new`, `acp.session.fork` or `_acpmux/handoff_start` (their replies
/// are read off the main thread), when the user opened it in this pane by a gesture (an attach made
/// with one, a click in the session list), or when the host itself opened the tab on it (restore,
/// a session link). An attach alone adds nothing; attach and watch stay open.
///
/// It also holds what the pane knows of handoffs, for the source rule
/// (``AcpmuxPaneMethods/sourceScoped``): each handoff's source session, read off the daemon's
/// replies, and the handoffs a click let the pane take from a session outside its scope.
public nonisolated final class AcpmuxPaneSessions: Sendable {
    /// The requests whose reply names a session the pane started.
    public static let starting: Set<String> = ["session/new", "acp.session.fork", "_acpmux/handoff_start"]

    private struct State {
        var sessions: Set<String> = []
        /// Raw JSON-RPC ids of the starting requests still waiting for their reply.
        var awaiting: Set<String> = []
        /// handoffId -> its source session, from the daemon's handoff records.
        var handoffSources: [String: String] = [:]
        /// The handoffs a click let the pane take from a session outside its scope.
        var ownedHandoffs: Set<String> = []
        /// Raw ids of the handoff requests still waiting for their record, and whether a click
        /// let the pane take that handoff.
        var awaitingHandoff: [String: Bool] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    public func add(_ session: String) { state.withLock { _ = $0.sessions.insert(session) } }

    public func contains(_ session: String) -> Bool { state.withLock { $0.sessions.contains(session) } }

    /// The requests whose reply is a handoff record (`handoffId`, `source.sessionId`).
    public static let handoffRecords: Set<String> = [
        "_acpmux/handoff_prepare", "_acpmux/handoff_get", "_acpmux/handoff_draft", "_acpmux/handoff_start",
    ]

    /// The pane sent `method` with raw id `id`: track what it starts or shows. `owned`: a click
    /// let the pane take this fork or handoff (`handoff`, when the frame names one) from a session
    /// outside its scope.
    func sent(method: String, id: String?, handoff: String? = nil, owned: Bool = false) {
        guard owned || Self.starting.contains(method) || Self.handoffRecords.contains(method) else { return }
        state.withLock { state in
            if owned, let handoff { state.ownedHandoffs.insert(handoff) }
            guard let id else { return }
            if Self.starting.contains(method) { state.awaiting.insert(id) }
            if Self.handoffRecords.contains(method) { state.awaitingHandoff[id] = owned }
        }
    }

    /// Whether the source of a fork or handoff frame (``AcpmuxPaneMethods/sourceScoped``) is in
    /// the pane's scope: a session of the pane, or a handoff from one (or one a click let the pane
    /// take). A handoff the pane never saw a record of is outside it.
    func holdsSource(_ params: [String: Any]) -> Bool {
        state.withLock { state in
            if let handoff = params["handoffId"] as? String {
                return state.ownedHandoffs.contains(handoff)
                    || state.handoffSources[handoff].map(state.sessions.contains) == true
            }
            guard let session = params["sessionId"] as? String else { return false }
            return state.sessions.contains(session)
        }
    }

    /// A daemon frame: when it answers a starting request, its sessions are the pane's; when it
    /// answers a handoff request, the pane learns the handoff's source.
    public func observe(_ text: String) {
        guard state.withLock({ !$0.awaiting.isEmpty || !$0.awaitingHandoff.isEmpty }), text.contains("\"result\""),
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        observe(object)
    }

    /// The same for a parsed daemon frame (its id already the page's).
    public func observe(_ object: [String: Any]) {
        guard object["method"] == nil, let result = object["result"] as? [String: Any],
              let id = object["id"].flatMap(AcpmuxPaneMethods.rawID),
              state.withLock({ !$0.awaiting.isEmpty || !$0.awaitingHandoff.isEmpty }) else { return }
        let named = ["sessionId", "targetSessionId"].compactMap { result[$0] as? String }
        let handoff = result["handoffId"] as? String
        let source = (result["source"] as? [String: Any])?["sessionId"] as? String
        state.withLock { state in
            if let owned = state.awaitingHandoff.removeValue(forKey: id), let handoff {
                if let source { state.handoffSources[handoff] = source }
                if owned { state.ownedHandoffs.insert(handoff) }
            }
            guard state.awaiting.remove(id) != nil else { return }
            state.sessions.formUnion(named)
        }
    }
}
