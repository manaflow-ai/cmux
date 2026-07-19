import Foundation

/// Converts Claude's provider payload into sanitized shared workload records.
struct ClaudeAgentWorkloadAdapter: Sendable {
    func workloads(from input: ClaudeHookParsedInput, now: TimeInterval) -> [AgentWorkloadRecord]? {
        guard let object = input.rawObject,
              object["background_tasks"] != nil || object["session_crons"] != nil else {
            return nil
        }
        var workloads: [AgentWorkloadRecord] = []
        if let tasks = object["background_tasks"] as? [[String: Any]] {
            workloads.append(contentsOf: tasks.enumerated().compactMap { index, task in
                let id = normalized(task["id"] as? String) ?? "background:\(index)"
                let status = normalized(task["status"] as? String)?.lowercased() ?? "unknown"
                let phase: AgentWorkloadPhase = switch status {
                case "queued", "pending": .queued
                case "running", "active": .running
                case "watching", "monitoring": .watching
                case "waiting": .waiting
                case "completed", "done", "success": .completed
                case "failed", "error": .failed
                case "cancelled", "canceled", "stopped": .cancelled
                default: .unknown
                }
                let type = normalized(task["type"] as? String)?.lowercased() ?? ""
                let kind: AgentWorkloadKind = switch type {
                case "shell", "bash", "terminal": .backgroundTerminal
                case "monitor", "watch": .monitor
                case "agent", "subagent": .subagent
                case "tool": .tool
                default: .other
                }
                return AgentWorkloadRecord(
                    id: id,
                    kind: kind,
                    phase: phase,
                    keepsSessionBusy: phase.isActive,
                    startedAt: now,
                    updatedAt: now,
                    endedAt: phase.isActive ? nil : now,
                    endReason: phase.isActive ? nil : "provider_\(phase.rawValue)"
                )
            })
        }
        if let crons = object["session_crons"] as? [[String: Any]] {
            workloads.append(contentsOf: crons.enumerated().map { index, cron in
                AgentWorkloadRecord(
                    id: normalized(cron["id"] as? String) ?? "scheduled:\(index)",
                    kind: .scheduled,
                    phase: .queued,
                    keepsSessionBusy: true,
                    startedAt: now,
                    updatedAt: now
                )
            })
        }
        return workloads
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
