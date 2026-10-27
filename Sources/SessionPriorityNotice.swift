import CMUXAgentLaunch
import Foundation

/// The notification for a session priority restart that left a pane without its Claude: the
/// pane restarted but the resume was never typed, so it shows a bare shell. Holds and refusals
/// change nothing and only show in the sidebar row.
struct SessionPriorityNotice: Equatable {
    let title: String
    let body: String

    /// For a restart to `target` whose resume `command` the user has to run.
    static func notRestarted(target: SessionPriorityTarget, command: String) -> SessionPriorityNotice {
        SessionPriorityNotice(
            title: String(
                localized: "notification.sessionPriority.title",
                defaultValue: "Claude effort not changed"
            ),
            body: String(
                format: String(
                    localized: "notification.sessionPriority.notRestarted",
                    defaultValue: "cmux restarted this terminal to set Claude effort to %1$@ but could not resume the conversation. Run: %2$@"
                ),
                locale: .current,
                SessionPriorityStatusRow.targetText(target) ?? "",
                command
            )
        )
    }

    /// Posts once, on the pane while it is still there, otherwise on its workspace, without
    /// moving focus.
    @MainActor
    func post(workspaceId: UUID, panelId: UUID) {
        let paneIsLive = AppDelegate.shared?.agentNotificationDeliveryTarget(
            claimedTabId: workspaceId,
            surfaceId: panelId
        ) != nil
        TerminalController.shared.deliverNotificationSynchronously(
            tabId: workspaceId,
            surfaceId: paneIsLive ? panelId : nil,
            title: title,
            subtitle: "",
            body: body
        )
    }
}
