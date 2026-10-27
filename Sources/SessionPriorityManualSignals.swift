import Foundation

/// Evidence that the user chose a pane's effort or model themselves.
enum SessionPriorityManualSignal: String, Sendable {
    /// The user marked the workspace manual.
    case flag
    /// The recorded launch command carries `--effort`.
    case launchArgumentEffort
    /// The workspace environment sets `CLAUDE_CODE_EFFORT_LEVEL`.
    case workspaceEnvironmentEffort
    /// The screen shows the result of a `/effort` or `/model` command.
    case userCommandOnScreen
}

enum SessionPriorityManualSignals {
    /// What Claude Code prints after `/effort` and `/model`.
    static let screenMarkers = ["Effort level set to", "Model set to"]

    /// The first signal found, in ``SessionPriorityManualSignal`` order, or `nil`.
    static func detect(
        userFlag: Bool,
        launchArguments: [String],
        workspaceEnvironment: [String: String],
        screenText: String?
    ) -> SessionPriorityManualSignal? {
        if userFlag { return .flag }
        if hasEffortArgument(launchArguments) { return .launchArgumentEffort }
        if let value = workspaceEnvironment["CLAUDE_CODE_EFFORT_LEVEL"],
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .workspaceEnvironmentEffort
        }
        if let screenText, screenMarkers.contains(where: { screenText.contains($0) }) {
            return .userCommandOnScreen
        }
        return nil
    }

    private static func hasEffortArgument(_ arguments: [String]) -> Bool {
        SessionPriorityLaunchArguments.value(ofOption: "--effort", in: arguments) != nil
    }
}
