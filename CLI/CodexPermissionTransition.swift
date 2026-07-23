struct CodexPermissionTransition: Equatable, Sendable {
    let state: CodexPermissionState
    let effect: CodexPermissionTransitionEffect
    let accepted: Bool
}
