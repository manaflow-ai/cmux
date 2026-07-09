import Foundation

/// Exact artifact scope for paths currently present in terminal text.
public struct TerminalArtifactScope: Sendable {
    private let terminalText: String
    private let workingDirectory: String?
    private let resolver: any ChatArtifactScope.FileSystemResolving
    private let detector: TerminalArtifactPathDetector

    /// Creates a terminal artifact scope checker.
    ///
    /// - Parameters:
    ///   - terminalText: Visible terminal text plus host scrollback.
    ///   - workingDirectory: Terminal cwd used to resolve relative path tokens.
    ///   - resolver: Filesystem resolver used for existence and canonicalization.
    ///   - detector: Path-token detector.
    public init(
        terminalText: String,
        workingDirectory: String?,
        resolver: any ChatArtifactScope.FileSystemResolving,
        detector: TerminalArtifactPathDetector = TerminalArtifactPathDetector()
    ) {
        self.terminalText = terminalText
        self.workingDirectory = workingDirectory
        self.resolver = resolver
        self.detector = detector
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
                  let canonical = ChatArtifactScope.canonicalizedPath(candidate, resolver: resolver),
                  !seen.contains(canonical) else {
                continue
            }
            seen.insert(canonical)
            result.append(canonical)
            if result.count >= limit { break }
        }
        return result
    }

    /// Resolves a request when its exact canonical path appears in terminal text.
    ///
    /// - Parameter path: Requested path, absolute or relative to the terminal cwd.
    /// - Returns: Canonical path when authorized, otherwise `nil`.
    public func canonicalPath(for path: String) -> String? {
        guard let absoluteRequest = absolutePath(for: path) else {
            return nil
        }
        guard let canonicalRequest = ChatArtifactScope.canonicalizedPath(absoluteRequest, resolver: resolver) else {
            return nil
        }
        var seen: Set<String> = []
        for candidate in detector.paths(in: terminalText).compactMap(absolutePath(for:)) {
            guard let canonical = ChatArtifactScope.canonicalizedPath(candidate, resolver: resolver),
                  !seen.contains(canonical) else {
                continue
            }
            seen.insert(canonical)
            if canonical == canonicalRequest {
                return canonicalRequest
            }
        }
        return nil
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
