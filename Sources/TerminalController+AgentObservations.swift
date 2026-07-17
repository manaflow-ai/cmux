import CmuxFoundation
import CmuxTerminal
import Foundation

extension TerminalController {
    /// Copies cached terminal classifications entirely on the socket worker.
    /// This never hops to the UI thread, captures terminal text, or scans processes.
    nonisolated func v2AgentObservations() -> [String: Any] {
        let observations = GhosttyApp.shared.agentTerminalObservationsSnapshot()
        guard let data = try? JSONEncoder().encode(observations),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [
                "runtime_id": TerminalSurface.managedCmuxRuntimeId,
                "observations": [],
            ]
        }
        return [
            "runtime_id": TerminalSurface.managedCmuxRuntimeId,
            "observations": payload,
        ]
    }
}
