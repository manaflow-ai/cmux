import Darwin

/// The filesystem seam used to discover executable Git installations.
nonisolated protocol GitExecutableFileProbing: Sendable {
    /// Returns whether `path` is an executable regular file.
    func isExecutableFile(atPath path: String) -> Bool
}

/// Probes executable paths through Foundation's filesystem API.
nonisolated struct SystemGitExecutableFileProbe: GitExecutableFileProbing {
    func isExecutableFile(atPath path: String) -> Bool {
        var metadata = stat()
        return Darwin.stat(path, &metadata) == 0
            && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && Darwin.access(path, X_OK) == 0
    }
}
