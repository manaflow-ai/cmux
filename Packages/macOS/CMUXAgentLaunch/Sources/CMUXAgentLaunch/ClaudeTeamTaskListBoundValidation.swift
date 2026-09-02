/// The result of validating one retained automatic-team binding in place.
enum ClaudeTeamTaskListBoundValidation {
    /// The canonical config still proves the binding, refreshed from disk.
    case matches(ClaudeTeamTaskListBinding)
    /// The canonical directory or config was removed during team cleanup.
    case missing
    /// The canonical config exists but no longer proves this hook identity.
    case doesNotMatch
}
