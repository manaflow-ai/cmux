import CMUXAgentLaunch

/// Closure bundle; binds to `FeedCoordinator` by default.
struct FeedRowActions {
    let approvePermission: (String, WorkstreamPermissionMode) -> Void
    let replyQuestion: (String, [String]) -> Void
    let approveExitPlan: (String, WorkstreamExitPlanMode, String?) -> Void
    let jump: (String) -> Void
    /// Types the user's reply into the agent's terminal surface and
    /// presses Return. Used by Stop-kind cards so the user can nudge
    /// Claude without switching focus to the terminal.
    let sendText: (String, String) -> Void

    static func bound() -> FeedRowActions {
        FeedRowActions(
            approvePermission: { requestID, mode in
                Task {
                    await FeedCoordinator.shared.deliverReply(
                        requestId: requestID,
                        decision: .permission(mode)
                    )
                }
            },
            replyQuestion: { requestID, selections in
                Task {
                    await FeedCoordinator.shared.deliverReply(
                        requestId: requestID,
                        decision: .question(selections: selections)
                    )
                }
            },
            approveExitPlan: { requestID, mode, feedback in
                Task {
                    await FeedCoordinator.shared.deliverReply(
                        requestId: requestID,
                        decision: .exitPlan(mode, feedback: feedback)
                    )
                }
            },
            jump: { workstreamId in
                Task {
                    _ = await FeedCoordinator.shared.focusIfPossible(workstreamId: workstreamId)
                }
            },
            sendText: { workstreamId, text in
                Task {
                    await FeedCoordinator.shared.sendTextToWorkstream(
                        workstreamId: workstreamId,
                        text: text
                    )
                }
            }
        )
    }
}
