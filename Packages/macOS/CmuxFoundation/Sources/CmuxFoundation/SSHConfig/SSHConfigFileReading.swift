/// Filesystem access seam used by ``SSHConfigHostAliasScanner``.
///
/// The scanner performs no I/O of its own; it reads config files and expands
/// `Include` globs exclusively through this protocol so parsing stays pure and
/// unit-testable. Production code uses ``SSHConfigFileSystemReader``; tests
/// inject an in-memory fake.
public protocol SSHConfigFileReading: Sendable {
    /// Returns the contents of the file at `path`, or `nil` when the file is
    /// missing, unreadable, or not a regular file.
    ///
    /// - Parameter path: An absolute file path.
    /// - Returns: The file contents decoded as UTF-8, or `nil`.
    func contentsOfFile(atPath path: String) -> String?

    /// Expands a shell-style glob pattern into matching file paths.
    ///
    /// Patterns without wildcards match at most the literal path itself.
    ///
    /// - Parameter pattern: An absolute path that may contain `*` or `?`.
    /// - Returns: Matching absolute paths in lexicographic order; empty when
    ///   nothing matches.
    func filePaths(matchingGlob pattern: String) -> [String]
}
