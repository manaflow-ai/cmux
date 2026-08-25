import Foundation

extension GitMetadataService {
    /// Detects SHA-256 object-format repositories before parsing a SHA-1 index.
    nonisolated func repositoryUsesSHA256ObjectIDs(
        repository: ResolvedGitRepository
    ) -> Bool {
        GitWorktreeConfigEnablementReader().isSHA256ObjectFormat(
            repository: repository,
            rootURLs: Self.gitRootConfigURLs(repository: repository)
        )
    }
}
