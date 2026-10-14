import Foundation

/// The agent CLI card's requests (cx-1mbnu): `harness.update` runs the CLI's own update on this
/// Mac's acpmux (`_acpmux/harness/update`) and waits for it; `harness.restart` restarts this
/// chat's agent on the installed version (`_acpmux/sessions/restart_harness`, after its turn).
/// The page names only a harness id; acpmux builds the command and refuses one needing sudo.
@MainActor
enum AgentPaneHarnessCard {
    static func reply(to request: AgentPaneRequest, transport: AgentPaneTransport, session sessionId: String?) async -> [String: Any] {
        // Page script cannot make a gesture: only the person's click updates or restarts.
        guard transport.gestures.consume() else {
            return AgentPaneReply.failure(code: "harness.gesture_required", message: AgentPaneModel.shellGestureMessage)
        }
        guard let socket = transport.acpmuxSocket else { return AgentPaneReply.failure(code: "harness.unavailable", message: unavailableMessage) }
        do {
            switch request {
            case .harnessUpdate(let id):
                // Each updater may run 15 minutes (acpmux `probe.rs`); an auto-update may hold the turn.
                let result = try await AcpmuxStatusClient.call(socketPath: socket, method: "_acpmux/harness/update", params: ["ids": [id]],
                                                               deadline: .seconds(35 * 60), detailed: true)
                let row = (result["results"] as? [[String: Any]])?.first { $0["id"] as? String == id }
                var value: [String: Any] = ["ok": row?["ok"] as? Bool ?? false]
                if let version = row?["version"] as? String { value["version"] = version }
                if let error = row?["error"] as? String { value["error"] = error }
                return AgentPaneReply.success(value)
            case .harnessRestart:
                guard let session = sessionId else { return AgentPaneReply.failure(code: "harness.unavailable", message: unavailableMessage) }
                let result = try await AcpmuxStatusClient.call(socketPath: socket, method: "_acpmux/sessions/restart_harness",
                                                               params: ["sessions": [session]], deadline: .seconds(300), detailed: true)
                return AgentPaneReply.success(["restarted": result["restarted"] as? Int ?? 0, "after_turn": result["after_turn"] as? Int ?? 0])
            default:
                return AgentPaneModel.unsupported("harness")
            }
        } catch AcpmuxStatusClient.Failure.rpc(let message) {
            return AgentPaneReply.failure(code: "harness.failed", message: message)
        } catch {
            // A refusal (`AcpmuxRPCError`) says why; an unreachable or closed daemon reads as not running.
            return AgentPaneReply.failure(code: "harness.failed", message: (error as? AcpmuxRPCError)?.message ?? unavailableMessage)
        }
    }

    /// The update or restart could not reach this Mac's agent service.
    static var unavailableMessage: String {
        String(localized: "agentPane.harness.unavailable", defaultValue: "The agent service is not running. Try again in a moment.", bundle: .module)
    }
}
