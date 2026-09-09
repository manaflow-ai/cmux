public import Foundation

/// Result of parsing private socket options that guard an agent-owned mutation.
///
/// Omission is valid and produces a `nil` ``value``; once any guard field is
/// present, every field for exactly one session or process guard is required.
public struct ControlSidebarAgentMutationGuardSocketResolution: Equatable, Sendable {
    /// Parsed guard, or `nil` when all guard options were omitted or invalid.
    public let value: ControlSidebarAgentMutationGuard?

    /// Whether the options were either omitted or formed one complete matching guard.
    public let isValid: Bool

    /// Parses private socket options emitted for an agent-owned mutation.
    ///
    /// - Parameters:
    ///   - options: Parsed socket options, without leading `--` markers.
    ///   - requiredStatusKey: Status key the guard must name. The default `nil`
    ///     accepts any status key for commands without a separate key argument.
    public init(
        _ options: [String: String],
        requiredStatusKey: String? = nil
    ) {
        let statusKeyRaw = options["expected-agent-key"]
        let sessionRaw = options["expected-agent-session-id"]
        let pidKeyRaw = options["expected-agent-pid-key"]
        let pidRaw = options["expected-agent-pid"]
        let secondsRaw = options["expected-agent-pid-start-seconds"]
        let microsecondsRaw = options["expected-agent-pid-start-microseconds"]
        let guardFields = [
            statusKeyRaw,
            sessionRaw,
            pidKeyRaw,
            pidRaw,
            secondsRaw,
            microsecondsRaw,
        ]
        if guardFields.allSatisfy({ $0 == nil }) {
            self.value = nil
            self.isValid = true
            return
        }
        guard let statusKey = statusKeyRaw?.controlSidebarAgentMutationGuardNormalized,
              requiredStatusKey == nil || requiredStatusKey == statusKey else {
            self.value = nil
            self.isValid = false
            return
        }

        let processFields = [pidKeyRaw, pidRaw, secondsRaw, microsecondsRaw]
        if let sessionID = sessionRaw?.controlSidebarAgentMutationGuardNormalized,
           processFields.allSatisfy({ $0 == nil }) {
            self.value = .session(statusKey: statusKey, sessionID: sessionID)
            self.isValid = true
            return
        }
        guard sessionRaw == nil,
              let pidKey = pidKeyRaw?.controlSidebarAgentMutationGuardNormalized,
              let normalizedPID = pidRaw?.controlSidebarAgentMutationGuardNormalized,
              let pid = Int32(normalizedPID),
              pid > 0,
              let normalizedSeconds = secondsRaw?.controlSidebarAgentMutationGuardNormalized,
              let seconds = Int64(normalizedSeconds),
              seconds >= 0,
              let normalizedMicroseconds = microsecondsRaw?.controlSidebarAgentMutationGuardNormalized,
              let microseconds = Int64(normalizedMicroseconds),
              microseconds >= 0,
              microseconds < 1_000_000 else {
            self.value = nil
            self.isValid = false
            return
        }
        self.value = .process(
            statusKey: statusKey,
            pidKey: pidKey,
            pid: pid,
            startSeconds: seconds,
            startMicroseconds: microseconds
        )
        self.isValid = true
    }
}

private extension String {
    var controlSidebarAgentMutationGuardNormalized: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
