@_spi(CmuxHostTransport) import CmuxExtensionKit
import Foundation

/// Builds a bounded read-only socket projection from native process/session evidence.
@MainActor
struct AgentRuntimeObservationReader {
    var projector = SidebarExtensionRuntimeProjector()

    func read(workspaces: [Workspace], surfaceID: UUID? = nil, limit: Int = 1_024) -> [String: Any] {
        var rows: [[String: Any]] = []
        var truncated = false
        let maximum = min(max(limit, 1), 1_024)
        outer: for workspace in workspaces.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            for panelID in workspace.panels.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                if let surfaceID, panelID != surfaceID { continue }
                for observation in projector.observations(workspace: workspace, panelID: panelID) ?? [] {
                    guard let tool = observation.toolID, let generation = observation.processGeneration else { continue }
                    let key = observation.sessionID.map { tool + "." + $0 } ?? tool
                    guard let pid = workspace.agentPIDs[key] else { continue }
                    guard rows.count < maximum else { truncated = true; break outer }
                    var row: [String: Any] = ["workspace_id": workspace.id.uuidString,
                        "surface_id": panelID.uuidString, "tool_id": tool, "pid": Int(pid),
                        "process_generation": generation, "activity": observation.activity.rawValue,
                        "mode": observation.mode.rawValue, "lifecycle": observation.lifecycle.rawValue,
                        "provenance": observation.provenance.rawValue]
                    row["session_id"] = observation.sessionID.map { $0 as Any } ?? NSNull()
                    row["reason"] = observation.reason.map { $0.rawValue as Any } ?? NSNull()
                    row["observed_at_ms"] = milliseconds(observation.observedAt) ?? NSNull()
                    row["transitioned_at_ms"] = milliseconds(observation.transitionedAt) ?? NSNull()
                    row["mode_observed_at_ms"] = milliseconds(observation.modeObservedAt) ?? NSNull()
                    row["sampled_at_ms"] = milliseconds(observation.sampledAt) ?? NSNull()
                    rows.append(row)
                }
            }
        }
        return ["schema_version": 1, "api_version": "2.2", "observations": rows, "truncated": truncated]
    }

    private func milliseconds(_ date: Date?) -> Any? {
        guard let value = date?.timeIntervalSince1970, value.isFinite,
              value >= 0, value < Double(Int64.max) / 1_000 else { return nil }
        return Int64(value * 1_000)
    }
}
