import CmuxCore
import Foundation

extension TerminalController {
    /// Worker-lane implementation shared by the CLI verb and any future
    /// command-palette/debug entry point. It never activates a window.
    nonisolated func reloadAgentManifests(_ rawArguments: String) -> String {
        let trimmedArguments = rawArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedArguments.isEmpty else {
            let format = String(
                localized: "cli.agentManifests.error.unexpectedArgument",
                defaultValue: "reload-agent-manifests does not accept arguments. Unexpected argument '%@'"
            )
            return "ERROR: \(String.localizedStringWithFormat(format, trimmedArguments))"
        }
        let runtime: CmuxAgentManifestRuntime? = v2MainSync(commandKey: "reload_agent_manifests") {
            AppDelegate.shared?.agentManifestRuntime
        }
        guard let runtime else {
            let message = String(
                localized: "cli.agentManifests.error.runtimeUnavailable",
                defaultValue: "Agent manifest reload is unavailable because cmux is still starting."
            )
            return "ERROR: \(message)"
        }
        let result: Result<CmuxAgentManifestSnapshot, CmuxAgentManifestLoadError>? = socketAwaitCallback(
            timeout: 30
        ) { completion in
            Task {
                completion(await runtime.reload())
            }
        }
        guard let result else {
            let format = String(
                localized: "cli.agentManifests.error.reloadTimeout",
                defaultValue: "Agent manifest reload timed out."
            )
            return "ERROR: \(format)"
        }
        switch result {
        case .success(let snapshot):
            let payload: [String: Any] = [
                "generation": snapshot.generation,
                "agents": snapshot.entries.map { $0.manifest.id },
                "count": snapshot.entries.count,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else {
                return "OK"
            }
            return "OK \(text)"
        case .failure(let error):
            let format = String(
                localized: "cli.agentManifests.error.reload",
                defaultValue: "Agent manifest reload failed: %@"
            )
            let message = String.localizedStringWithFormat(format, error.localizedDescription)
            return "ERROR: \(message)"
        }
    }
}
