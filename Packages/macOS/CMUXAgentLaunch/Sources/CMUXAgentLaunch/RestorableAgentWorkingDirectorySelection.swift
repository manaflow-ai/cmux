import Foundation

/// Selects whether agent restore may consult cwd values recorded with the agent process.
public enum RestorableAgentWorkingDirectorySelection: Sendable {
    /// Prefer the supplied cwd, then fall back through the agent and launch snapshots.
    case recordedFallback(preferred: String?)
    /// Use only the supplied cwd; an explicit `nil` must remain `nil`.
    case exact(String?)

    /// Whether captured argv cwd options must be discarded instead of value-matched.
    public var discardsRecordedCwdOptions: Bool {
        switch self {
        case .recordedFallback:
            false
        case .exact:
            true
        }
    }

    public func resolved(
        snapshotWorkingDirectory: String?,
        launchWorkingDirectory: String?
    ) -> String? {
        let candidates: [String?] = switch self {
        case .recordedFallback(let preferred):
            [preferred, snapshotWorkingDirectory, launchWorkingDirectory]
        case .exact(let workingDirectory):
            [workingDirectory]
        }
        for candidate in candidates {
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                continue
            }
            return trimmed
        }
        return nil
    }
}
