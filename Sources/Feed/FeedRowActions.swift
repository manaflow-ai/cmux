import CMUXAgentLaunch
import Foundation

/// Closure bundle; binds to `FeedCoordinator` by default.
struct FeedRowActions {
    let approvePermission: @MainActor (String, WorkstreamPermissionMode) -> Void
    let replyQuestion: @MainActor (String, [String]) -> Void
    let approveExitPlan: @MainActor (String, WorkstreamExitPlanMode, String?) -> Void
    let jump: @MainActor (String) -> Void
    let remove: @MainActor (UUID) -> Void
    /// Types the user's reply into the agent's terminal surface and
    /// presses Return. Used by Stop-kind cards so the user can nudge
    /// Claude without switching focus to the terminal.
    let sendText: @MainActor (String, String, @escaping @MainActor (Bool) -> Void) -> Void

    @MainActor
    final class TaskStore {
        private var tasks: [UUID: Task<Void, Never>] = [:]

        deinit {
            for task in tasks.values {
                task.cancel()
            }
        }

        func run(_ operation: @escaping @MainActor () async -> Void) {
            let id = UUID()
            tasks[id] = Task { [weak self] in
                await operation()
                self?.tasks.removeValue(forKey: id)
            }
        }
    }

    @MainActor
    static func bound(taskStore: TaskStore) -> FeedRowActions {
        FeedRowActions(
            approvePermission: { requestID, mode in
                taskStore.run {
                    await FeedCoordinator.shared.deliverReply(
                        requestId: requestID,
                        decision: .permission(mode)
                    )
                }
            },
            replyQuestion: { requestID, selections in
                taskStore.run {
                    await FeedCoordinator.shared.deliverReply(
                        requestId: requestID,
                        decision: .question(selections: selections)
                    )
                }
            },
            approveExitPlan: { requestID, mode, feedback in
                taskStore.run {
                    await FeedCoordinator.shared.deliverReply(
                        requestId: requestID,
                        decision: .exitPlan(mode, feedback: feedback)
                    )
                }
            },
            jump: { workstreamId in
                taskStore.run {
                    _ = await FeedCoordinator.shared.focusIfPossible(workstreamId: workstreamId)
                }
            },
            remove: { itemID in
                taskStore.run {
                    _ = await FeedCoordinator.shared.removeItem(id: itemID)
                }
            },
            sendText: { workstreamId, text, completion in
                taskStore.run {
                    let sent = await FeedCoordinator.shared.sendTextToWorkstream(
                        workstreamId: workstreamId,
                        text: text
                    )
                    guard !Task.isCancelled else { return }
                    completion(sent)
                }
            }
        )
    }
}
