import CmuxCore
import Foundation

extension TerminalController {
    /// Bridges synchronous socket workers to the actor-owned immutable catalog.
    ///
    /// - Important: Call only from a socket worker. The callback bridge blocks
    ///   its calling thread while the actor responds.
    nonisolated func currentAgentManifestStateForSocketCommand() -> (
        snapshot: CmuxAgentManifestSnapshot?,
        error: CmuxAgentManifestLoadError?
    )? {
        assert(
            !Thread.isMainThread,
            "Agent manifest snapshot waits must remain off the main thread"
        )
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
