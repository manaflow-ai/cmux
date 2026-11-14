import CMUXAgentLaunch
import Foundation

/// Evidence that the user chose a pane's effort or model themselves.
enum SessionPriorityManualSignal: String, Sendable {
    /// The user marked the workspace manual.
    case flag
    /// The recorded launch command carries `--effort`.
    case launchArgumentEffort
    /// The recorded launch environment sets `CLAUDE_CODE_EFFORT_LEVEL` without cmux's equal
    /// `CMUX_SESSION_PRIORITY_EFFORT` mark: typed before `claude` or exported by the shell.
    case launchEnvironmentEffort
    /// The workspace environment sets `CLAUDE_CODE_EFFORT_LEVEL`.
    case workspaceEnvironmentEffort
    /// The user ran `/effort` or `/model`: the screen shows its result, or the conversation
    /// transcript records it after cmux last restarted the pane or was asked to adjust it
    /// again. The raw value is the wire value from before the transcript was read.
    case userCommandOnScreen
}

enum SessionPriorityManualSignals {
    /// What Claude Code prints after `/effort` and `/model`, the same text the transcript probe
    /// looks for.
    static let screenMarkers = ClaudeTranscriptLocalCommandProbe.changeMarkers

    /// The first signal found, in ``SessionPriorityManualSignal`` order, or `nil`.
    static func detect(
        userFlag: Bool,
        launchArguments: [String],
        launchEnvironment: [String: String],
        workspaceEnvironment: [String: String],
        screenText: String?
    ) -> SessionPriorityManualSignal? {
        if userFlag { return .flag }
        if hasEffortArgument(launchArguments) { return .launchArgumentEffort }
        // cmux's own resume marks the level it sets; any other recorded level is the user's.
        if let level = nonBlank(launchEnvironment[ClaudeEffortLevel.environmentKey]),
           launchEnvironment[ClaudeEffortLevel.sessionPriorityMarkerKey] != level {
            return .launchEnvironmentEffort
        }
        if nonBlank(workspaceEnvironment[ClaudeEffortLevel.environmentKey]) != nil {
            return .workspaceEnvironmentEffort
        }
        if let screenText, screenMarkers.contains(where: { screenText.contains($0) }) {
            return .userCommandOnScreen
        }
        return nil
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func hasEffortArgument(_ arguments: [String]) -> Bool {
        SessionPriorityLaunchArguments.value(ofOption: "--effort", in: arguments) != nil
    }
}
