/// An ordered Codex tool/permission observation.
enum CodexPermissionEvent: Equatable, Sendable {
    case permissionRequested
    case toolStarted
    case toolCompleted
}
