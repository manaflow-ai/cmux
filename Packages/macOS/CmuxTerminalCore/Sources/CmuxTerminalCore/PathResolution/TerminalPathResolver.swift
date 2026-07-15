public import Foundation

/// Resolves file-system paths out of raw terminal text.
///
/// This is the shared path heuristics layer behind cmd-click QuickLook,
/// "open file at cursor", and terminal link opening. Candidate spellings come
/// from the pure `String` transforms in this domain (shell-token unquoting
/// and unescaping, trailing-punctuation trimming, visible-line
/// tokenization); the resolver expands them for `~`, resolves relative
/// candidates against an ordered surface context, standardizes, and probes in
/// order. Optional `:line[:column]` suffixes survive as structured metadata.
///
/// The resolver is an instantiated value because resolution is pure only up
/// to the file system: every resolve probes candidates for existence, so the
/// file-existence capability is injected at init. Production uses the real
/// file system; tests inject a fake probe. This mirrors
/// ``TerminalLinkRouter``'s injected `BrowserHostNormalizing` seam.
public nonisolated struct TerminalPathResolver: Sendable {
    private static let explicitURLSchemes: Set<String> = [
        "file", "ftp", "gemini", "git", "gopher", "http", "https", "ipfs",
        "ipns", "magnet", "mailto", "news", "ssh", "tel",
    ]
    private let fileExists: @Sendable (String) -> Bool

    /// Creates a resolver that probes candidate paths through `fileExists`.
    ///
    /// - Parameter fileExists: The file-existence capability; defaults to the
    ///   real file system.
    public init(
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.fileExists = fileExists
    }

    /// Resolves terminal text to an existing absolute path and source location.
    ///
    /// Literal spellings are probed before treating a numeric suffix as source
    /// location metadata. Relative spellings are resolved against the surface
    /// working directory, then each fallback root. Only an existing path is
    /// returned.
    ///
    /// - Parameters:
    ///   - rawText: The raw terminal token or selected text.
    ///   - context: The surface working directory and ordered fallback roots.
    /// - Returns: The first existing path reference, or `nil`.
    public func resolvePath(
        _ rawText: String,
        context: TerminalPathResolutionContext
    ) -> TerminalPathResolution? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let spellings = trimmed.pathResolutionCandidates()
        guard !spellings.contains(where: hasExplicitURLScheme) else {
            return nil
        }
        let references = spellings.filter { !shouldBypassPathResolutionForURL($0) }.flatMap {
            $0.terminalPathReferenceCandidates()
        }
        let directories = resolutionDirectories(context: context)
        var seenPaths: Set<String> = []

        for directory in directories {
            for reference in references {
                let expandedPath = (reference.path as NSString).expandingTildeInPath
                guard !expandedPath.hasPrefix("/") else { continue }
                let candidatePath = (directory as NSString).appendingPathComponent(expandedPath)
                if let resolution = existingResolution(
                    path: candidatePath,
                    line: reference.line,
                    column: reference.column,
                    seenPaths: &seenPaths
                ) {
                    return resolution
                }
            }
        }

        for reference in references {
            let expandedPath = (reference.path as NSString).expandingTildeInPath
            guard expandedPath.hasPrefix("/") else { continue }
            if let resolution = existingResolution(
                path: expandedPath,
                line: reference.line,
                column: reference.column,
                seenPaths: &seenPaths
            ) {
                return resolution
            }
        }

        return nil
    }

    /// Resolves raw terminal text to an existing file path for QuickLook.
    ///
    /// Candidates are derived from the raw text (as-is, shell-unescaped,
    /// shell-unquoted, and trailing-punctuation-trimmed variants), expanded
    /// for `~`, resolved against `cwd` when relative, standardized, and probed
    /// in order. The first existing path wins.
    ///
    /// - Parameters:
    ///   - rawText: The raw text under the cursor or selection.
    ///   - cwd: The surface's working directory used for relative candidates.
    /// - Returns: The first existing standardized path, or `nil`.
    public func resolveQuicklookPath(_ rawText: String, cwd: String?) -> String? {
        resolvePath(
            rawText,
            context: TerminalPathResolutionContext(workingDirectory: cwd)
        )?.path
    }

    /// Resolves the path token under a column of a visible terminal line.
    ///
    /// Tries the raw whitespace-delimited segment around the column first,
    /// then the shell-escape-aware token, and resolves each through
    /// ``resolveQuicklookPath(_:cwd:)``.
    ///
    /// - Parameters:
    ///   - line: The visible line text.
    ///   - column: The zero-based column under the cursor.
    ///   - cwd: The surface's working directory.
    /// - Returns: The raw token plus its resolved path, or `nil`.
    public func resolveVisibleLinePath(
        _ line: String,
        column: Int,
        cwd: String
    ) -> (rawToken: String, path: String)? {
        for rawToken in line.pathTokenCandidates(containingColumn: column) {
            if let resolvedPath = resolveQuicklookPath(rawToken, cwd: cwd) {
                return (rawToken, resolvedPath)
            }
        }
        return nil
    }

    /// Resolves the path reference under a visible terminal column.
    ///
    /// - Parameters:
    ///   - line: The visible line text.
    ///   - column: The zero-based column under the cursor.
    ///   - context: The surface working directory and ordered fallback roots.
    /// - Returns: The raw token plus its structured resolution, or `nil`.
    public func resolveVisibleLineReference(
        _ line: String,
        column: Int,
        context: TerminalPathResolutionContext
    ) -> (rawToken: String, resolution: TerminalPathResolution)? {
        for rawToken in line.pathTokenCandidates(containingColumn: column) {
            if let resolution = resolvePath(rawToken, context: context) {
                return (rawToken, resolution)
            }
        }
        return nil
    }

    /// Resolves an open-URL request payload to an existing file path.
    ///
    /// Text that parses as a URL with a scheme is never treated as a file
    /// path; everything else goes through ``resolveQuicklookPath(_:cwd:)``.
    ///
    /// - Parameters:
    ///   - rawText: The raw open-URL text from the runtime.
    ///   - cwd: The surface's working directory.
    /// - Returns: The first existing standardized path, or `nil`.
    public func resolveOpenURLFilePath(_ rawText: String, cwd: String?) -> String? {
        resolveOpenURLFileReference(
            rawText,
            context: TerminalPathResolutionContext(workingDirectory: cwd)
        )?.path
    }

    /// Resolves an open-URL payload as an existing local path reference.
    ///
    /// Explicit URL schemes remain on the URL-routing path. Schemeless text is
    /// resolved through ``resolvePath(_:context:)``.
    ///
    /// - Parameters:
    ///   - rawText: The raw open-URL text from the runtime.
    ///   - context: The surface working directory and ordered fallback roots.
    /// - Returns: The first existing path reference, or `nil`.
    public func resolveOpenURLFileReference(
        _ rawText: String,
        context: TerminalPathResolutionContext
    ) -> TerminalPathResolution? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return resolvePath(trimmed, context: context)
    }

    /// Whether an unresolved relative-path-shaped callback should be consumed.
    ///
    /// Existing references must continue through file routing; only a
    /// relative-looking token that failed existence-gated resolution is
    /// consumed to prevent the browser fallback from guessing it as a URL.
    public func shouldConsumeUnresolvedOpenURLPathReference(
        _ rawText: String,
        resolvedReference: TerminalPathResolution?
    ) -> Bool {
        resolvedReference == nil && isRelativePathReferenceCandidate(rawText)
    }

    /// Whether text is unambiguously shaped like a relative path reference.
    ///
    /// This classifier is used only after existence-gated resolution fails, so
    /// callers can consume path-like text instead of passing it to a browser
    /// heuristic. Bare domains remain URL candidates; explicit path prefixes,
    /// non-host path heads, and file-like source-location suffixes are paths.
    ///
    /// - Parameter rawText: Raw text from a terminal link callback.
    /// - Returns: `true` when unresolved text should not be guessed as a URL.
    public func isRelativePathReferenceCandidate(_ rawText: String) -> Bool {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let spellings = trimmed.pathResolutionCandidates()
        guard !spellings.contains(where: hasExplicitURLScheme) else { return false }
        for spelling in spellings {
            guard !shouldBypassPathResolutionForURL(spelling) else { continue }
            for reference in spelling.terminalPathReferenceCandidates() {
                let path = reference.path
                guard !(path as NSString).isAbsolutePath else { continue }
                if path.hasPrefix("./") || path.hasPrefix("../") || path.hasPrefix("~/") {
                    return true
                }
                if reference.line != nil, path.contains(".") {
                    return true
                }
            }
        }
        return false
    }

    private func shouldBypassPathResolutionForURL(_ rawText: String) -> Bool {
        if isHostPortReference(rawText) { return true }
        guard let scheme = URL(string: rawText)?.scheme?.lowercased() else { return false }
        guard !hasExplicitURLScheme(rawText, parsedScheme: scheme) else { return true }

        // Foundation also parses `File.swift:12` and `Makefile:12` as custom
        // URL schemes. A numeric location suffix remains eligible because the
        // resolver still requires the stripped path to exist; an arbitrary
        // `scheme:value` stays on the URL route.
        return !rawText.terminalPathReferenceCandidates().contains { $0.line != nil }
    }

    private func isHostPortReference(_ rawText: String) -> Bool {
        guard let separator = rawText.lastIndex(of: ":"),
              let port = Int(rawText[rawText.index(after: separator)...]),
              (0...65_535).contains(port) else {
            return false
        }
        let host = String(rawText[..<separator]).lowercased()
        if host == "localhost" { return true }
        if host.hasPrefix("["), host.hasSuffix("]") {
            return URLComponents(string: "http://\(rawText)")?.host != nil
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { octet in
            guard let value = UInt8(octet) else { return false }
            return String(value) == String(octet)
        }
    }

    private func hasExplicitURLScheme(_ rawText: String) -> Bool {
        guard let scheme = URL(string: rawText)?.scheme?.lowercased() else { return false }
        return hasExplicitURLScheme(rawText, parsedScheme: scheme)
    }

    private func hasExplicitURLScheme(_ rawText: String, parsedScheme: String) -> Bool {
        Self.explicitURLSchemes.contains(parsedScheme) || rawText.contains("://")
    }

    private func resolutionDirectories(
        context: TerminalPathResolutionContext
    ) -> [String] {
        var directories: [String] = []
        for rawDirectory in [context.workingDirectory].compactMap({ $0 }) + context.fallbackDirectories {
            let trimmed = rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let expanded = (trimmed as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { continue }
            let standardized = (expanded as NSString).standardizingPath
            guard !directories.contains(standardized) else { continue }
            directories.append(standardized)
        }
        return directories
    }

    private func existingResolution(
        path: String,
        line: Int?,
        column: Int?,
        seenPaths: inout Set<String>
    ) -> TerminalPathResolution? {
        let standardizedPath = (path as NSString).standardizingPath
        guard seenPaths.insert(standardizedPath).inserted else { return nil }
        guard fileExists(standardizedPath) else { return nil }
        return TerminalPathResolution(
            path: standardizedPath,
            line: line,
            column: column
        )
    }
}
