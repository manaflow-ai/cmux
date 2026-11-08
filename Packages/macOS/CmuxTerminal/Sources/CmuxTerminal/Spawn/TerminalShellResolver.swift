internal import Foundation

/// Selects an executable login shell from macOS user and shell declarations.
///
/// The resolver is pure apart from the injected executable check. Production
/// supplies values from the user database, `$SHELL`, and `/etc/shells`; tests
/// can model relocated package-manager paths without changing the host Mac.
public struct TerminalShellResolver: Sendable {
    private let isExecutable: @Sendable (String) -> Bool

    /// Creates a shell resolver with an injected executable check.
    ///
    /// - Parameter isExecutable: Returns whether an absolute path names an
    ///   executable file.
    public init(isExecutable: @escaping @Sendable (String) -> Bool) {
        self.isExecutable = isExecutable
    }

    /// Resolves the first executable shell while preserving the user's shell family.
    ///
    /// User-database and environment values are authoritative when executable.
    /// If both point at stale installations, a declared shell with the same
    /// basename is preferred before the system fallback chain. A non-executable
    /// candidate is never returned.
    ///
    /// - Parameters:
    ///   - loginShell: The current user's shell from the macOS user database.
    ///   - environmentShell: The process's inherited `$SHELL` value.
    ///   - declaredShells: Shell paths declared by `/etc/shells`.
    ///   - fallbackShells: Known-safe system fallback candidates.
    /// - Returns: An executable absolute shell path, or `nil` when none exists.
    public func resolve(
        loginShell: String?,
        environmentShell: String?,
        declaredShells: [String],
        fallbackShells: [String] = ["/bin/zsh", "/bin/sh"]
    ) -> String? {
        let loginCandidate = normalizedAbsolutePath(loginShell)
        let environmentCandidate = normalizedAbsolutePath(environmentShell)
        let declaredCandidates = declaredShells.compactMap(normalizedAbsolutePath)
        let preferredShellNames = [loginCandidate, environmentCandidate]
            .compactMap { $0 }
            .map(lastPathComponent)
        let relocatedPreferredShells = declaredCandidates.filter {
            preferredShellNames.contains(lastPathComponent($0))
        }
        let candidates = [loginCandidate, environmentCandidate].compactMap { $0 }
            + relocatedPreferredShells
            + fallbackShells.compactMap(normalizedAbsolutePath)
            + declaredCandidates

        var visited: Set<String> = []
        for candidate in candidates where visited.insert(candidate).inserted {
            if isExecutable(candidate) {
                return candidate
            }
        }
        return nil
    }

    private func normalizedAbsolutePath(_ candidate: String?) -> String? {
        guard let candidate else { return nil }
        let path = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), path != "/" else { return nil }
        return path
    }

    private func lastPathComponent(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}
