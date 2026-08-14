import CmuxCore
import Foundation

extension TerminalController {
    /// Bridges synchronous socket workers to the actor-owned immutable catalog.
    nonisolated func currentAgentManifestStateForSocketCommand() -> (
        snapshot: CmuxAgentManifestSnapshot?,
        error: CmuxAgentManifestLoadError?
    )? {
        let runtime: CmuxAgentManifestRuntime? = v2MainSync(
            commandKey: "agent_manifest_snapshot"
        ) {
            AppDelegate.shared?.agentManifestRuntime
        }
        guard let runtime else { return nil }
        return socketAwaitCallback(timeout: 5) { completion in
            Task {
                completion(await runtime.state())
            }
        }
    }
}
