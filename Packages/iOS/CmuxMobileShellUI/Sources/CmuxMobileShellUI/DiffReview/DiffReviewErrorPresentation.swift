import CmuxMobileRPC
import CmuxMobileSupport

struct DiffReviewErrorPresentation {
    let message: String

    init(error: any Error) {
        message = Self.makeMessage(for: error)
    }

    private static func makeMessage(for error: any Error) -> String {
        guard let connectionError = error as? MobileShellConnectionError else {
            return unavailableMessage
        }
        switch connectionError {
        case .rpcError(let code, _):
            switch code {
            case "not_found":
                return L10n.string(
                    "mobile.diff.error.notFound",
                    defaultValue: "Git repository or file not found"
                )
            case "git_failed":
                return L10n.string(
                    "mobile.diff.error.gitFailed",
                    defaultValue: "Could not read repository changes"
                )
            case "stale_repository":
                return L10n.string(
                    "mobile.diff.error.repositoryChanged",
                    defaultValue: "Workspace repository changed. Refresh changes."
                )
            default:
                return unavailableMessage
            }
        case .requestTimedOut:
            return L10n.string(
                "mobile.diff.error.timedOut",
                defaultValue: "The paired Mac took too long to load changes"
            )
        default:
            return unavailableMessage
        }
    }

    private static var unavailableMessage: String {
        L10n.string("mobile.diff.unavailable", defaultValue: "Diff unavailable")
    }
}
