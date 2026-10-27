import CMUXAgentLaunch
import Foundation

/// The notification for a session priority restart that left a pane without its Claude: the
/// pane restarted but the resume was never typed, so it shows a bare shell. Holds and refusals
/// change nothing and only show in the sidebar row.
///
/// Each reason gets the account switch's wording (`ClaudeAccountSwitchNotice`), so a Claude
/// still running is never resumed a second time and a closed pane is not called "this terminal".
struct SessionPriorityNotice: Equatable {
    let title: String
    let body: String

    /// For a restart to `target` whose resume the user has to run, for `manual`'s reason.
    static func notRestarted(target: SessionPriorityTarget, manual: ClaudeAccountSwitchManualResume) -> SessionPriorityNotice {
        let changed = targetDescription(target)
        let body: String
        switch manual.reason {
        case .notTyped:
            body = String(
                format: String(
                    localized: "notification.sessionPriority.notTyped",
                    defaultValue: "cmux restarted this terminal to apply %1$@ but couldn't resume the conversation. To continue it, run this command in the terminal:\n\n%2$@"
                ),
                locale: .current,
                changed,
                manual.command
            )
        case .paneReplaced:
            body = String(
                format: String(
                    localized: "notification.sessionPriority.paneReplaced",
                    defaultValue: "The terminal was closed before cmux could resume the conversation with %1$@. To continue it, run this command in a terminal:\n\n%2$@"
                ),
                locale: .current,
                changed,
                manual.command
            )
        case .previousClaudeStillRunning(let processIDs):
            body = String(
                format: String(
                    localized: "notification.sessionPriority.previousClaudeStillRunning",
                    defaultValue: "The previous Claude (process %1$@) is still running, so cmux didn't resume the conversation with %2$@ here: it would run in two places. Once that Claude has quit, run this command in this terminal:\n\n%3$@"
                ),
                locale: .current,
                processIDs.map(String.init).joined(separator: ", "),
                changed,
                manual.command
            )
        }
        return SessionPriorityNotice(title: title(target), body: body)
    }

    private static func title(_ target: SessionPriorityTarget) -> String {
        if target.effort == nil, target.model != nil {
            return String(localized: "notification.sessionPriority.title.model", defaultValue: "Claude model not changed")
        }
        return String(localized: "notification.sessionPriority.title", defaultValue: "Claude effort not changed")
    }

    /// The effort and the model the restart was for, naming only those the target sets. Effort
    /// levels and models are technical identifiers, shown as they are. A restart always has one
    /// of them; an empty target reads as an empty effort.
    static func targetDescription(_ target: SessionPriorityTarget) -> String {
        switch (target.effort, target.model) {
        case let (effort?, model?):
            return String(
                format: String(
                    localized: "notification.sessionPriority.target.effortAndModel",
                    defaultValue: "Claude effort %1$@ and model %2$@"
                ),
                locale: .current,
                effort.rawValue,
                model
            )
        case let (nil, model?):
            return String(
                format: String(localized: "notification.sessionPriority.target.model", defaultValue: "Claude model %@"),
                locale: .current,
                model
            )
        case let (effort, nil):
            return String(
                format: String(localized: "notification.sessionPriority.target.effort", defaultValue: "Claude effort %@"),
                locale: .current,
                effort?.rawValue ?? ""
            )
        }
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
