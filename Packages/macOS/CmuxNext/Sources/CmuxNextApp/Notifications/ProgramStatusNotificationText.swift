import CmuxNextDaemon
import Foundation

/// The body of a program status notification (`notification-program-status-v1`)
/// in the user's language: what the program waits for, or that it failed, then
/// the program's message. The message stays plain text (a banner, the feed and
/// the panel show it as text; it is never a link or a command).
extension NotificationProgramStatus {
    nonisolated var localizedBody: String {
        guard let msg, !msg.isEmpty else { return wording }
        let format = String(localized: "notification.programStatus.withMessage", defaultValue: "%1$@: %2$@",
                            bundle: .module)
        return String(format: format, wording, msg)
    }

    nonisolated private var wording: String {
        switch (state, kind) {
        case (.error, _):
            String(localized: "notification.programStatus.failed", defaultValue: "Failed", bundle: .module)
        case (.blocked, .permission):
            String(localized: "notification.programStatus.needsApproval", defaultValue: "Needs approval", bundle: .module)
        case (.blocked, .question):
            String(localized: "notification.programStatus.asksQuestion", defaultValue: "Asks a question", bundle: .module)
        case (.blocked, .auth):
            String(localized: "notification.programStatus.needsSignIn", defaultValue: "Needs sign-in", bundle: .module)
        case (.blocked, nil):
            String(localized: "notification.programStatus.needsInput", defaultValue: "Needs input", bundle: .module)
        }
    }
}

extension NotificationCenterService {
    /// The body to show for `notification`: the localized program status
    /// body when the daemon sent `program_status`, else the daemon's body.
    nonisolated static func body(of notification: DaemonNotification) -> String {
        notification.programStatus?.localizedBody ?? notification.body
    }
}
