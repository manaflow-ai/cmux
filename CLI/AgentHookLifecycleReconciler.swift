import Darwin
import Foundation

/// Converts an agent's authoritative lifecycle signal into an existing generic
/// hook action. The adapter is provider-neutral; protocol extensions only need
/// to publish the canonical `agent_state` and optional `turn_outcome` fields.
struct AgentHookLifecycleReconciler {
    enum Route: Equatable {
        case running
        case notification
        case terminalNotification
        case stop
        case ignore
        case rejectStaleProcess
    }

    func route(
        subcommand: String,
        payload: [String: Any]?,
        processID: Int?
    ) -> Route? {
        guard subcommand == "lifecycle" else { return nil }
        let state = normalized(payload?["agent_state"])
        switch state {
        case "running":
            return Self.processExists(processID) ? .running : .rejectStaleProcess
        case "awaiting-approval", "needs-input":
            return Self.processExists(processID) ? .notification : .rejectStaleProcess
        case "idle":
            let outcome = normalized(payload?["turn_outcome"])
            switch outcome {
            case "done", "complete", "completed", "cancelled", "canceled", "interrupted":
                return .stop
            case "error", "failed":
                return .terminalNotification
            default:
                return .ignore
            }
        case "error":
            return .terminalNotification
        default:
            return .ignore
        }
    }

    private static func normalized(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        return normalized.isEmpty ? nil : normalized
    }

    private static func processExists(_ processID: Int?) -> Bool {
        guard let processID, processID > 0 else { return false }
        errno = 0
        return kill(pid_t(processID), 0) == 0 || errno == EPERM
    }
}
