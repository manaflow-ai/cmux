import Foundation

/// Artifact scope for paths currently present in terminal text and authorized descendants.
public struct TerminalArtifactScope: Sendable {
    private let terminalText: String
    private let workingDirectory: String?
    private let resolver: any ChatArtifactScope.FileSystemResolving
    private let detector: TerminalArtifactPathDetector
    private let canonicalizer: ChatArtifactPathCanonicalizer
    private let directoryAccessMode: ChatArtifactScope.DirectoryAccessMode

    /// Creates a terminal artifact scope checker.
    ///
    /// - Parameters:
    ///   - terminalText: Visible terminal text plus host scrollback.
    ///   - workingDirectory: Terminal cwd used to resolve relative path tokens.
    ///   - resolver: Filesystem resolver used for existence and canonicalization.
    ///   - detector: Path-token detector.
    ///   - canonicalizer: Filesystem identity operation used to de-duplicate rows.
    ///   - directoryAccessMode: Descendant authorization policy. The default
    ///     preserves exact/one-level legacy behavior for existing callers.
    public init(
        terminalText: String,
        workingDirectory: String?,
        resolver: any ChatArtifactScope.FileSystemResolving,
        detector: TerminalArtifactPathDetector = TerminalArtifactPathDetector(),
        canonicalizer: ChatArtifactPathCanonicalizer = ChatArtifactPathCanonicalizer(),
        directoryAccessMode: ChatArtifactScope.DirectoryAccessMode = .oneLevel
    ) {
        self.terminalText = terminalText
        self.workingDirectory = workingDirectory
        self.resolver = resolver
        self.detector = detector
        self.canonicalizer = canonicalizer
        self.directoryAccessMode = directoryAccessMode
    }

    /// Current terminal artifact paths, canonicalized, existing, deduped, and capped.
    ///
    /// - Parameter limit: Maximum paths to return.
    /// - Returns: Canonical absolute paths authorized by the terminal text.
    public func artifactPaths(limit: Int = 200) -> [String] {
        let candidates = detector.paths(in: terminalText).compactMap(absolutePath(for:))
        var seen: Set<String> = []
        var result: [String] = []
        for candidate in candidates {
            guard resolver.isDirectory(candidate) != nil,
                  let resolved = ChatArtifactScope.canonicalizedPath(candidate, resolver: resolver) else {
                continue
            }
            let canonical = canonicalizer.canonicalPathKey(for: resolved)
            guard seen.insert(canonical).inserted else {
                continue
            }
            result.append(canonical)
            if result.count >= limit { break }
        }
        return result
    }

    /// Resolves a file request against canonical visible paths and directory policy.
    ///
    /// - Parameter path: Requested path, absolute or relative to the terminal cwd.
    /// - Returns: Canonical path when authorized, otherwise `nil`.
    public func canonicalPath(for path: String) -> String? {
        guard let absoluteRequest = absolutePath(for: path),
              let canonicalRequest = canonicalIdentity(for: absoluteRequest) else {
            return nil
        }
        return artifactScope().canonicalFilePath(for: canonicalRequest)
    }

    /// Resolves a directory-list request against canonical visible paths and policy.
    ///
    /// - Parameter path: Requested path, absolute or relative to the terminal cwd.
    /// - Returns: Canonical directory path when authorized, otherwise `nil`.
    public func canonicalDirectoryListPath(for path: String) -> String? {
        guard let absoluteRequest = absolutePath(for: path),
              let canonicalRequest = canonicalIdentity(for: absoluteRequest) else {
            return nil
        }
        return artifactScope().canonicalDirectoryListPath(for: canonicalRequest)
    }

    private func artifactScope() -> ChatArtifactScope {
        ChatArtifactScope(
            referencedPaths: Set(
                detector.paths(in: terminalText)
                    .compactMap(absolutePath(for:))
                    .compactMap(canonicalIdentity(for:))
            ),
            directoryAccessMode: directoryAccessMode,
            resolver: resolver
        )
    }

    private func canonicalIdentity(for path: String) -> String? {
        guard let resolved = ChatArtifactScope.canonicalizedPath(path, resolver: resolver) else {
            return nil
        }
        return canonicalizer.canonicalPathKey(for: resolved)
    }

    private func absolutePath(for token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") {
            return (trimmed as NSString).standardizingPath
        }
        guard let workingDirectory,
              !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let combined = (workingDirectory as NSString).appendingPathComponent(trimmed)
        return (combined as NSString).standardizingPath
    }
}
