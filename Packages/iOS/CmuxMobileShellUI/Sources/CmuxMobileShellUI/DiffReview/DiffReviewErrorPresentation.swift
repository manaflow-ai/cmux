import CmuxDiffModel
import CmuxMobileSupport

struct DiffReviewErrorPresentation {
    let message: String

    init(error: any Error) {
        let unavailableMessage = L10n.string(
            "mobile.diff.unavailable",
            defaultValue: "Diff unavailable"
        )
        guard let diffError = error as? WorkspaceDiffError else {
            message = unavailableMessage
            return
        }
        switch diffError {
        case .notFound:
            message = L10n.string(
                "mobile.diff.error.notFound",
                defaultValue: "Git repository or file not found"
            )
        case .gitFailed:
            message = L10n.string(
                "mobile.diff.error.gitFailed",
                defaultValue: "Could not read repository changes"
            )
        case .timedOut:
            message = L10n.string(
                "mobile.diff.error.timedOut",
                defaultValue: "The paired Mac took too long to load changes"
            )
        case .staleRepository:
            message = L10n.string(
                "mobile.diff.error.repositoryChanged",
                defaultValue: "Workspace repository changed. Refresh changes."
            )
        case .unavailable:
            message = unavailableMessage
        }
    }
}
