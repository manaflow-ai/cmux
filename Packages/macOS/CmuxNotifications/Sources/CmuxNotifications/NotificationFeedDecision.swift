/// A feed decision produced from an OS notification action.
public enum NotificationFeedDecision: Sendable, Equatable {
    /// A permission decision.
    case permission(NotificationFeedPermissionMode)

    /// An exit-plan decision.
    case exitPlan(NotificationFeedExitPlanMode, feedback: String?)

    /// A question decision carrying the selected option ids or a custom answer.
    case question(selections: [String])
}
