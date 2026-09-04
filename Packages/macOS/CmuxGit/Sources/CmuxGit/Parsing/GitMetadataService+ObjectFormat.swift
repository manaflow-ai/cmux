import Foundation
import Dispatch

extension GitMetadataService {
    /// Detects SHA-256 object-format repositories before parsing a SHA-1 index.
    nonisolated func repositoryUsesSHA256ObjectIDs(
        repository: ResolvedGitRepository,
        deadline: DispatchTime? = nil,
        branchContext: GitConfigBranchContext = .fileBacked
    ) -> Bool? {
        GitWorktreeConfigEnablementReader().isSHA256ObjectFormat(
            repository: repository,
            rootURLs: GitWorktreeConfigEnablementReader().rootConfigURLs(
                repository: repository,
                deadline: deadline,
                branchContext: branchContext
            ),
            deadline: deadline,
            branchContext: branchContext
        )
    }
}
