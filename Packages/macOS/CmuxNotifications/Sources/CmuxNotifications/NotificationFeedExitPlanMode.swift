/// Exit-plan modes that can be returned from a feed exit-plan notification
/// action.
public enum NotificationFeedExitPlanMode: String, Sendable, Equatable {
    /// Accept the plan through Ultraplan.
    case ultraplan

    /// Bypass permissions while accepting the plan.
    case bypassPermissions

    /// Accept automatically.
    case autoAccept

    /// Accept manually.
    case manual

    /// Deny the plan.
    case deny
}
