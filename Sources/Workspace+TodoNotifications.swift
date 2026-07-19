import CmuxWorkspaces
import Foundation

/// Transition notifications for a workspace's todo state: a single cmux
/// notification when the effective status first reaches `.done`, and one when
/// the checklist first becomes fully complete (n/n, n > 0). Both reuse the
/// same delivery path as the app's other workspace-level notifications
/// (`AppDelegate.shared.notificationStore.addNotification`, `surfaceId: nil`),
/// mirroring `Workspace.applyRemoteConnectionStateUpdate`.
///
/// The `Workspace+Todos` mutation entry points route their mutation through
/// the `notifying…` wrappers below, which sample the before/after state and
/// fire only on the crossing edge, so the notification is emitted once per
/// transition regardless of whether the user, the CLI, or an agent (socket)
/// drove the change. A short cooldown key guards against a duplicate landing
/// from two entry points in the same tick.
extension Workspace {
    /// Whether the checklist is non-empty and every item is completed.
    var checklistIsFullyComplete: Bool {
        let summary = checklistProgressSummary
        return summary.totalCount > 0 && summary.completedCount == summary.totalCount
    }

    /// Runs a status mutation and posts the "done" notification when the
    /// effective status crossed from non-done to `.done`.
    @discardableResult
    func notifyingStatusTransition<T>(_ mutate: () -> T) -> T {
        let wasDone = effectiveTaskStatus == .done
        let result = mutate()
        if !wasDone, effectiveTaskStatus == .done {
            postWorkspaceStatusDoneNotification()
        }
        return result
    }

    /// Runs a checklist mutation and posts the "complete" notification when
    /// the checklist crossed from not-fully-complete to fully complete.
    @discardableResult
    func notifyingChecklistCompletion<T>(_ mutate: () -> T) -> T {
        let wasComplete = checklistIsFullyComplete
        let result = mutate()
        if !wasComplete, checklistIsFullyComplete {
            postChecklistCompleteNotification()
        }
        return result
    }

    private func postWorkspaceStatusDoneNotification() {
        AppDelegate.shared?.notificationStore?.addNotification(
            tabId: id,
            surfaceId: nil,
            title: String(
                localized: "workspace.todo.notification.doneTitle",
                defaultValue: "Workspace marked done"
            ),
            subtitle: title,
            body: String(
                localized: "workspace.todo.notification.doneBody",
                defaultValue: "This workspace's status is now done."
            ),
            cooldownKey: "workspace-todo-status-done-\(id.uuidString)",
            cooldownInterval: Self.todoNotificationCooldown
        )
    }

    private func postChecklistCompleteNotification() {
        AppDelegate.shared?.notificationStore?.addNotification(
            tabId: id,
            surfaceId: nil,
            title: String(
                localized: "workspace.todo.notification.checklistCompleteTitle",
                defaultValue: "Checklist complete"
            ),
            subtitle: title,
            body: String(
                localized: "workspace.todo.notification.checklistCompleteBody",
                defaultValue: "Every checklist item is done."
            ),
            cooldownKey: "workspace-todo-checklist-complete-\(id.uuidString)",
            cooldownInterval: Self.todoNotificationCooldown
        )
    }

    /// Coalesce window so the same transition posted from two entry points in
    /// one tick delivers a single notification.
    private static let todoNotificationCooldown: TimeInterval = 3
}
