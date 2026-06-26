/// Outcome of resolving a `rg` (ripgrep) executable.
///
/// Distinguishes the case where the user configured an explicit binary path
/// that turned out not to be executable (`configuredPathNotExecutable`, so the
/// caller can surface that path in an error) from the plain not-found case.
public enum RipgrepExecutableResolution: Equatable, Sendable {
    /// A usable `rg` executable was resolved.
    case found(FileSearchRipgrepExecutable)
    /// The user-configured path exists in settings but is not executable; the
    /// associated value is the normalized configured path.
    case configuredPathNotExecutable(String)
    /// No `rg` executable was found in the configured path, known default
    /// locations, or `PATH`.
    case notFound
}
