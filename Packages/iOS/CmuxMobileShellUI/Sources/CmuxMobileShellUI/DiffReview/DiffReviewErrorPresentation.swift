import CmuxDiffModel
import CmuxMobileSupport

struct DiffReviewErrorPresentation {
    let message: String

    init(error: any Error) {
        message = Self.makeMessage(for: error)
    }

    private static func makeMessage(for error: any Error) -> String {
        guard let diffError = error as? WorkspaceDiffError else {
            return unavailableMessage
        }
        switch diffError {
        case .notFound:
            return L10n.string(
                "mobile.diff.error.notFound",
                defaultValue: "Git repository or file not found"
            )
        case .gitFailed:
            return L10n.string(
                "mobile.diff.error.gitFailed",
                defaultValue: "Could not read repository changes"
            )
        case .timedOut:
            return L10n.string(
                "mobile.diff.error.timedOut",
                defaultValue: "The paired Mac took too long to load changes"
            )
        case .staleRepository:
            return L10n.string(
                "mobile.diff.error.repositoryChanged",
                defaultValue: "Workspace repository changed. Refresh changes."
            )
        case .unavailable:
            return unavailableMessage
        }
    }

    private static var unavailableMessage: String {
        L10n.string("mobile.diff.unavailable", defaultValue: "Diff unavailable")
    }
}
