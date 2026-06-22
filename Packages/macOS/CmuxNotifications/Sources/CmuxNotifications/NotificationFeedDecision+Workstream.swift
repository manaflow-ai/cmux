public import CMUXAgentLaunch

extension NotificationFeedDecision {
    /// The workstream decision equivalent of this feed decision.
    ///
    /// OS notification actions yield a ``NotificationFeedDecision`` in this
    /// domain's vocabulary; the feed delivery seam consumes the agent-runtime
    /// `WorkstreamDecision`. The case names and wire raw values are identical
    /// across both enums, so this is a one-to-one translation that preserves
    /// the existing wire format.
    public var workstreamDecision: WorkstreamDecision {
        switch self {
        case .permission(let mode):
            return .permission(mode.workstreamPermissionMode)
        case .exitPlan(let mode):
            return .exitPlan(mode.workstreamExitPlanMode)
        }
    }
}

extension NotificationFeedPermissionMode {
    /// The workstream permission mode equivalent of this feed permission mode.
    public var workstreamPermissionMode: WorkstreamPermissionMode {
        switch self {
        case .once:
            return .once
        case .always:
            return .always
        case .all:
            return .all
        case .bypass:
            return .bypass
        case .deny:
            return .deny
        }
    }
}

extension NotificationFeedExitPlanMode {
    /// The workstream exit-plan mode equivalent of this feed exit-plan mode.
    public var workstreamExitPlanMode: WorkstreamExitPlanMode {
        switch self {
        case .ultraplan:
            return .ultraplan
        case .bypassPermissions:
            return .bypassPermissions
        case .autoAccept:
            return .autoAccept
        case .manual:
            return .manual
        case .deny:
            return .deny
        }
    }
}
