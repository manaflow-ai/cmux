import Darwin

/// The filesystem seam used to identify a repository's reference backend.
nonisolated protocol GitReferenceStorageProbing: Sendable {
    /// Returns whether `path` currently resolves to a directory.
    func isDirectory(atPath path: String) -> Bool
}

/// Probes reference-storage directories through Foundation's filesystem API.
nonisolated struct SystemGitReferenceStorageProbe: GitReferenceStorageProbing {
    func isDirectory(atPath path: String) -> Bool {
        var metadata = stat()
        return Darwin.stat(path, &metadata) == 0
            && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }
}
