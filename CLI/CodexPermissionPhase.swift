enum CodexPermissionPhase: String, Codable, Equatable, Sendable {
    case toolStarted
    case needsInput
    case resumed
}
