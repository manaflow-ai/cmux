import Foundation

struct CodexPermissionTransition: Equatable, Sendable {
    let state: CodexPermissionState
    let effect: CodexPermissionTransitionEffect
    let accepted: Bool
    let resolvedNotificationID: UUID?

    init(
        state: CodexPermissionState,
        effect: CodexPermissionTransitionEffect,
        accepted: Bool,
        resolvedNotificationID: UUID? = nil
    ) {
        self.state = state
        self.effect = effect
        self.accepted = accepted
        self.resolvedNotificationID = resolvedNotificationID
    }
}
