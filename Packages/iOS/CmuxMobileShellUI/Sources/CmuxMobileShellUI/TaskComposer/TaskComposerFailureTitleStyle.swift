#if os(iOS)
import CmuxMobileShell
import CmuxMobileSupport

enum TaskComposerFailureTitleStyle: Equatable {
    case launchFailed
    case statusUnconfirmed
    case taskAccepted

    var title: String {
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
            return L10n.string(
                "mobile.taskComposer.failure.title",
                defaultValue: "Couldn’t start this task"
            )
        }
    }

    init(failure: MobileWorkspaceMutationFailure) {
        switch failure {
        case .alreadyCompleted:
            self = .taskAccepted
        case .notConnected, .requestTimedOut:
            self = .statusUnconfirmed
        default:
            self = .launchFailed
        }
    }
}
#endif
