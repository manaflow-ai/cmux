import Foundation

/// The agent CLI card's requests (cx-1mbnu): `harness.update` runs the CLI's own update on this
/// Mac's acpmux (`_acpmux/harness/update`) and waits for it; `harness.restart` restarts this
/// chat's agent on the installed version (`_acpmux/sessions/restart_harness`, after its turn).
/// The page names only a harness id; acpmux builds the command and refuses one needing sudo.
@MainActor
enum AgentPaneHarnessCard {
    static func reply(to request: AgentPaneRequest, transport: AgentPaneTransport, session sessionId: String?,
                      host: (any AgentPaneHostProviding)? = nil) async -> [String: Any] {
        // Page script cannot make a gesture: only the person's click updates or restarts.
        guard transport.gestures.consume() else {
            return AgentPaneReply.failure(code: "harness.gesture_required", message: AgentPaneModel.shellGestureMessage)
        }
        guard let socket = transport.acpmuxSocket else { return AgentPaneReply.failure(code: "harness.unavailable", message: unavailableMessage) }
        let first = await call(request, transport: transport, session: sessionId, socket: socket)
        // An agent service from before this app's update lacks the request: the app restarts it on its
        // own build (its chats kept) and asks once more, rather than asking the person to quit cmux.
        guard first.outdated, let host, let restarted = await host.restartOutdatedAcpmux(sessionId: sessionId) else { return first.reply }
        let again = await call(request, transport: transport, session: sessionId, socket: restarted)
        return again.outdated ? AgentPaneReply.failure(code: "harness.failed", message: oldServiceMessage) : again.reply
    }

    /// One try of `request` on the acpmux at `socket`; `outdated` when that service lacks the method.
    private static func call(_ request: AgentPaneRequest, transport: AgentPaneTransport, session sessionId: String?,
                             socket: String) async -> (reply: [String: Any], outdated: Bool) {
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
                return (AgentPaneReply.success(value), false)
            case .harnessRestart:
                // Only a chat this pane started or shows: the page can adopt any id (`chat.persistSession`).
                guard let session = sessionId, transport.sessions.contains(session) else {
                    return (AgentPaneReply.failure(code: "harness.not_this_chat", message: unavailableMessage), false)
                }
                let result = try await AcpmuxStatusClient.call(socketPath: socket, method: "_acpmux/sessions/restart_harness",
                                                               params: ["sessions": [session]], deadline: .seconds(300), detailed: true)
                var value: [String: Any] = ["restarted": result["restarted"] as? Int ?? 0, "after_turn": result["after_turn"] as? Int ?? 0,
                                            "failed": result["failed"] as? Int ?? 0]
                if let error = (result["errors"] as? [[String: Any]])?.first?["error"] as? String { value["error"] = error }
                return (AgentPaneReply.success(value), false)
            default:
                return (AgentPaneModel.unsupported("harness"), false)
            }
        } catch AcpmuxStatusClient.Failure.rpc(let message) {
            return (AgentPaneReply.failure(code: "harness.failed", message: message), false)
        } catch let error as AcpmuxRPCError {
            // An agent service from before this app's update does not know the method yet.
            let message = error.isMethodMissing ? oldServiceMessage : error.isUnreachable ? unavailableMessage : error.message
            return (AgentPaneReply.failure(code: "harness.failed", message: message), error.isMethodMissing)
        } catch is AgentPaneDeadlineExceeded {
            return (AgentPaneReply.failure(code: "harness.failed", message: slowMessage), false)
        } catch {
            return (AgentPaneReply.failure(code: "harness.failed", message: unavailableMessage), false)
        }
    }

    /// The agent service is still older than the app (it lacks the method) after the app's own restart.
    static var oldServiceMessage: String {
        String(localized: "agentPane.harness.oldService",
               defaultValue: "cmux couldn't update its agent service. Quit and reopen cmux, then try again.", bundle: .module)
    }

    /// The update or restart outlived its deadline; it may still finish.
    static var slowMessage: String {
        String(localized: "agentPane.harness.slow",
               defaultValue: "This is taking longer than expected. It may still finish; check Settings > Agents.", bundle: .module)
    }

    /// The update or restart could not reach this Mac's agent service.
    static var unavailableMessage: String {
        String(localized: "agentPane.harness.unavailable", defaultValue: "The agent service is not running. Try again in a moment.", bundle: .module)
    }
}
