import Foundation
import Dispatch

extension GitMetadataService {
    /// Detects SHA-256 object-format repositories before parsing a SHA-1 index.
    nonisolated func repositoryUsesSHA256ObjectIDs(
        repository: ResolvedGitRepository,
        deadline: DispatchTime? = nil
    ) -> Bool {
        GitWorktreeConfigEnablementReader().isSHA256ObjectFormat(
            repository: repository,
            rootURLs: Self.gitRootConfigURLs(repository: repository, deadline: deadline),
            deadline: deadline
        )
    }
}
