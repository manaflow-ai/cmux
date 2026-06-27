public import CMUXAgentLaunch
import Foundation

/// Closure bundle that a Feed row invokes for its interactive actions. It holds
/// only value snapshots and closures so it can live below the Feed list's
/// snapshot boundary and be passed down to rows without any reference to a live
/// store. The app composition root binds these closures to the live coordinator
/// (`FeedRowActions.bound()`); previews bind logging stubs instead.
public struct FeedRowActions {
    public let approvePermission: (UUID, WorkstreamPermissionMode) -> Void
    public let replyQuestion: (UUID, [String]) -> Void
    public let approveExitPlan: (UUID, WorkstreamExitPlanMode, String?) -> Void
    public let jump: (String) -> Void
    /// Types the user's reply into the agent's terminal surface and
    /// presses Return. Used by Stop-kind cards so the user can nudge
    /// Claude without switching focus to the terminal.
    public let sendText: (String, String) -> Void

    public init(
        approvePermission: @escaping (UUID, WorkstreamPermissionMode) -> Void,
        replyQuestion: @escaping (UUID, [String]) -> Void,
        approveExitPlan: @escaping (UUID, WorkstreamExitPlanMode, String?) -> Void,
        jump: @escaping (String) -> Void,
        sendText: @escaping (String, String) -> Void
    ) {
        self.approvePermission = approvePermission
        self.replyQuestion = replyQuestion
        self.approveExitPlan = approveExitPlan
        self.jump = jump
        self.sendText = sendText
    }
}
