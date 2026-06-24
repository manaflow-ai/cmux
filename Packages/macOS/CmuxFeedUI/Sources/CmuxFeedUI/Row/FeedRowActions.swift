public import CMUXAgentLaunch
public import Foundation

/// Closure bundle a feed row uses to deliver the user's decisions back to the
/// app without holding a reference to any store or coordinator.
///
/// Rows receive a value of this type (the snapshot-boundary rule), so every
/// action is a plain closure over ``CMUXAgentLaunch`` value types. The app
/// builds the live bundle (binding the closures to its feed coordinator);
/// debug fixtures build a logging bundle. ``FeedRowActions`` itself knows
/// nothing about either.
public struct FeedRowActions {
    /// Delivers a permission decision for the item with the given id.
    public let approvePermission: (UUID, WorkstreamPermissionMode) -> Void
    /// Delivers the selected answers to a question item.
    public let replyQuestion: (UUID, [String]) -> Void
    /// Delivers an exit-plan decision (mode plus optional refinement feedback).
    public let approveExitPlan: (UUID, WorkstreamExitPlanMode, String?) -> Void
    /// Focuses the workstream identified by the given id.
    public let jump: (String) -> Void
    /// Types the user's reply into the agent's terminal surface and
    /// presses Return. Used by Stop-kind cards so the user can nudge
    /// Claude without switching focus to the terminal.
    public let sendText: (String, String) -> Void

    /// Creates a feed row action bundle.
    /// - Parameters:
    ///   - approvePermission: Delivers a permission decision for an item id.
    ///   - replyQuestion: Delivers the selected answers to a question item.
    ///   - approveExitPlan: Delivers an exit-plan decision plus optional
    ///     refinement feedback.
    ///   - jump: Focuses the workstream identified by the given id.
    ///   - sendText: Types the user's reply into the agent's terminal surface.
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
