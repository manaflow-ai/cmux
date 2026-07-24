enum CodexPermissionTransitionEffect: Equatable, Sendable {
    case none
    case projectNeedsInput
    case resolvePermission
    case resolveNeedsInput
}
