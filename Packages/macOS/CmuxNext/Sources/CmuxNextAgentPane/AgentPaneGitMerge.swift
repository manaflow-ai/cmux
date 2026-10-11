import Foundation

/// Merge from the PR chip (cx-ncc.77.4, Codex desktop's): the branch's pull request merges only
/// when it is the one the page showed, open and not a draft, GitHub calls its merge state clean
/// (checks, reviews and conflicts settled) with every check passed, and its head is this Mac's
/// HEAD. gh then merges exactly that head with the user's default method; nothing is pushed and no
/// branch is deleted.
extension AgentPaneGitPullRequest {
    static let mergeFields = "url,number,state,isDraft,mergeStateStatus,headRefOid,statusCheckRollup"

    @concurrent static func merge(_ number: Int, in folder: String, gh: String) async -> Outcome {
        .refused(mergeNotReadyMessage)
    }

    /// The branch's pull request is not the one the page showed.
    nonisolated static var mergeChangedMessage: String {
        String(localized: "agentPane.error.gitMergeChanged",
               defaultValue: "This branch's pull request changed. Look at it again before merging.", bundle: .module)
    }

    /// The pull request is merged or closed.
    nonisolated static var mergeNotOpenMessage: String {
        String(localized: "agentPane.error.gitMergeNotOpen", defaultValue: "This pull request isn't open.", bundle: .module)
    }

    /// A draft, a check not passed, or GitHub's merge state not clean (a review, conflicts).
    nonisolated static var mergeNotReadyMessage: String {
        String(localized: "agentPane.error.gitMergeNotReady",
               defaultValue: "GitHub says this pull request isn't ready to merge: a check, a review or a conflict is still open.",
               bundle: .module)
    }

    /// This Mac's HEAD is not the pull request's head.
    nonisolated static var mergeHeadMessage: String {
        String(localized: "agentPane.error.gitMergeHead",
               defaultValue: "This branch here isn't the pull request's head. Push or pull first, then merge.", bundle: .module)
    }
}
