import Darwin
import Foundation

/// Converts an agent's authoritative lifecycle signal into an existing generic
/// hook action. The adapter is provider-neutral; protocol extensions only need
/// to publish the canonical `agent_state` and optional `turn_outcome` fields.
public struct AgentHookLifecycleReconciler: Sendable {
    /// The generic action selected for an agent lifecycle event.
    public enum Route: Equatable, Sendable {
        case running
        case notification
        case terminalNotification
        case stop(publishesCompletionNotification: Bool)
        case ignore
        case rejectStaleProcess
    }

    public init() {}

    /// Returns the generic action for a lifecycle payload, if it is a lifecycle event.
    public func route(
        subcommand: String,
        payload: [String: Any]?,
        processID: Int?,
        allowsSnapshotWithoutLiveProcess: Bool = false
    ) -> Route? {
        guard subcommand == "lifecycle" else { return nil }
        let state = Self.normalized(payload?["agent_state"])
        switch state {
        case "running":
            return allowsSnapshotWithoutLiveProcess || Self.processExists(processID)
                ? .running
                : .rejectStaleProcess
        case "awaiting-approval", "needs-input":
            return allowsSnapshotWithoutLiveProcess || Self.processExists(processID)
                ? .notification
                : .rejectStaleProcess
        case "idle":
            let outcome = Self.normalized(payload?["turn_outcome"])
            switch outcome {
            case "done", "complete", "completed":
                return .stop(publishesCompletionNotification: true)
            case "cancelled", "canceled", "interrupted":
                return .stop(publishesCompletionNotification: false)
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
