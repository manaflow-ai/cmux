#if os(iOS)
import CmuxMobileShell
import CmuxMobileSupport
import Foundation

enum TaskComposerFailureTitleStyle: Equatable {
    case launchFailed
    case statusUnconfirmed
    case taskAccepted

    func title(templateName: String?) -> String {
        switch self {
        case .statusUnconfirmed:
            return L10n.string(
                "mobile.taskComposer.failure.title.statusUnconfirmed",
                defaultValue: "Task status unconfirmed"
            )
        case .taskAccepted:
            return L10n.string(
                "mobile.taskComposer.failure.title.taskAccepted",
                defaultValue: "Task already accepted"
            )
        case .launchFailed:
            guard let templateName = templateName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !templateName.isEmpty else {
                return L10n.string(
                    "mobile.taskComposer.failure.title",
                    defaultValue: "Couldn’t start this task"
                )
            }
            return String.localizedStringWithFormat(
                L10n.string(
                    "mobile.taskComposer.failure.titleFormat",
                    defaultValue: "Couldn’t start %@"
                ),
                templateName
            )
        }
    }

    static func forFailure(_ failure: MobileWorkspaceMutationFailure) -> Self {
        switch failure {
        case .alreadyCompleted:
            .taskAccepted
        case .notConnected, .requestTimedOut:
            .statusUnconfirmed
        default:
            .launchFailed
        }
    }
}
#endif
