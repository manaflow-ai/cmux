import Foundation

extension AcpmuxPaneSocket {
    /// acpmux's visibility op (p14-energy-117): a hidden idle session's harness may be frozen.
    nonisolated static let visibilityMethod = "_acpmux/visibility"

    /// `_acpmux/visibility {sessionId, visible}` as a JSON-RPC notification: it has no `id`, so no
    /// reply comes back to wait on, and it is not a request (the person proof stays the
    /// connection's second request, `hub/person.rs`).
    nonisolated static func visibilityFrame(session: String, visible: Bool) -> String? {
        let frame: [String: Any] = ["jsonrpc": "2.0", "method": visibilityMethod,
                                    "params": ["sessionId": session, "visible": visible]]
        guard let data = try? JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Hands acpmux whether anybody can see `session` (``visibilityFrame(session:visible:)``), under
    /// the same outstanding bounds as every send; nil when the socket took it. It never waits.
    nonisolated func sendVisibility(session: String, visible: Bool) -> AgentPaneTransportError? {
        guard let frame = Self.visibilityFrame(session: session, visible: visible) else { return .invalidFrame }
        return send(frame)
    }
}
