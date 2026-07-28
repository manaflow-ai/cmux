import Foundation

/// Matches live executables against cmux-recorded launch metadata.
public struct AgentLaunchExecutableMatcher: Sendable {
    /// Creates a launch-executable matcher.
    public init() {}

    /// Returns whether a live executable matches cmux-recorded launch metadata.
    ///
    /// - Parameters:
    ///   - kind: The agent kind being validated.
    ///   - executableCandidates: Live process names or executable paths.
    ///   - recordedKind: The value captured in `CMUX_AGENT_LAUNCH_KIND`.
    ///   - recordedExecutable: The value captured in
    ///     `CMUX_AGENT_LAUNCH_EXECUTABLE`.
    /// - Returns: `true` when the recorded kind describes `kind` and a live
    ///   executable basename matches the recorded executable basename.
    public func matches(
        kind: String,
        executableCandidates: [String],
        recordedKind: String?,
        recordedExecutable: String?
    ) -> Bool {
        guard let recordedKind = normalizedAgentName(recordedKind),
              let normalizedKind = normalizedAgentName(kind),
              (recordedKind == normalizedKind
                  || AgentLaunchCaptureTrust.launcherDescribesKind(
                      recordedKind,
                      kind: normalizedKind
                  )),
              let recordedExecutable = processBasename(recordedExecutable) else {
            return false
        }
        return executableCandidates.contains { candidate in
            processBasename(candidate) == recordedExecutable
        }
    }

    private func normalizedAgentName(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }

    private func processBasename(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: value).lastPathComponent.lowercased()
    }
}
