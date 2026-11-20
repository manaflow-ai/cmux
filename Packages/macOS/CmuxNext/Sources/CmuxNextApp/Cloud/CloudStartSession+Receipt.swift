import CmuxNextActions
import Foundation

/// A confirmed start on the team's VM. The chat link uses the same identity as the team publisher.
extension CloudStartSession {
    nonisolated static func receipt(machine: String, name: String, session: String, host: String, agent: String,
                              workspace: String, surface: String, tab: String, stages: [(step: String, ms: Int64)],
                              team: String?, scheme: String?) -> [String: ActionResultValue] {
        var answer: [String: ActionResultValue] = [
            "machine_id": .string(machine), "machine_name": .string(name), "target": .string("machine:\(machine)"),
            "session_id": .string(session), "host": .string(host), "agent": .string(agent),
            "workspace_id": .string(workspace), "surface_id": .string(surface), "tab_id": .string(tab),
            "stages_ms": .array(stages.map { .object(["step": .string($0.step), "ms": .int(Int($0.ms))]) }),
        ]
        if let scheme {
            let teamLink = team.flatMap { DeepLink(.cloudSession(team: $0, machine: machine, session: session, kind: .chat)).url(scheme: scheme) }
            if let url = teamLink ?? DeepLink(.tab(tab)).url(scheme: scheme) { answer["link"] = .string(url.absoluteString) }
        }
        return answer
    }
}
