import Foundation
import CmuxGit

/// One off-main read of a directory's git metadata, applied back on the main
/// actor to every panel that joined the probe for that directory.
struct InitialWorkspaceGitMetadataSnapshot: Equatable, Sendable {
    /// The pull-request portion of a metadata snapshot.
    ///
    /// The initial local probe only ever produces `.deferred` (a branch was
    /// found; the PR poll service will resolve it) or `.notFound`; the other
    /// cases are preserved from the legacy snapshot shape so the apply path's
    /// state transitions stay byte-identical.
    enum PullRequest: Equatable, Sendable {
        case deferred
        case unsupportedRepository
        case notFound
        case resolved(SidebarPullRequestBadge)
        case transientFailure
    }

    let isRepository: Bool
    let branch: String?
    let isDirty: Bool
    let indexSignature: String?
    let indexContentSignature: String?
    let headSignature: String?
    let pullRequest: PullRequest

    /// Probes `directory` through `reader` and folds the result into a
    /// snapshot (branch normalized; PR deferred only when a branch exists).
    init(
        probing directory: String,
        reader: any WorkspaceGitMetadataReading,
        trackedPathEventGeneration: UInt64? = nil
    ) async {
        let metadata = await reader.workspaceMetadata(
            for: directory,
            trackedPathEventGeneration: trackedPathEventGeneration
        )
        guard metadata.isRepository else {
            self.init(
                isRepository: false,
                branch: nil,
                isDirty: false,
                indexSignature: nil,
                indexContentSignature: nil,
                headSignature: nil,
                pullRequest: .notFound
            )
            return
        }

        let branch = GitMetadataService.normalizedBranchName(metadata.branch)
        self.init(
            isRepository: true,
            branch: branch,
            isDirty: metadata.isDirty,
            indexSignature: metadata.indexSignature,
            indexContentSignature: metadata.indexContentSignature,
            headSignature: metadata.headSignature,
            pullRequest: branch == nil ? .notFound : .deferred
        )
    }

    init(
        isRepository: Bool,
        branch: String?,
        isDirty: Bool,
        indexSignature: String?,
        indexContentSignature: String?,
        headSignature: String?,
        pullRequest: PullRequest
    ) {
        self.isRepository = isRepository
        self.branch = branch
        self.isDirty = isDirty
        self.indexSignature = indexSignature
        self.indexContentSignature = indexContentSignature
        self.headSignature = headSignature
        self.pullRequest = pullRequest
    }
}
