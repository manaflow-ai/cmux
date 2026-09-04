public import Foundation

/// Resolves file-system paths out of raw terminal text.
///
/// This is the shared path heuristics layer behind cmd-click QuickLook,
/// "open file at cursor", and terminal link opening. Candidate spellings come
/// from the pure `String` transforms in this domain (shell-token unquoting
/// and unescaping, trailing-punctuation trimming, visible-line
/// tokenization); the resolver expands them for `~`, resolves relative
/// candidates against the surface cwd, standardizes, and probes in order.
///
/// The resolver is an instantiated value because resolution is pure only up
/// to the file system: every resolve probes candidates for existence, so the
/// file-existence capability is injected at init. Production uses the real
/// file system; tests inject a fake probe. This mirrors
/// ``TerminalLinkRouter``'s injected `BrowserHostNormalizing` seam.
public struct TerminalPathResolver: Sendable {
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
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var seenPaths: Set<String> = []
        for token in trimmed.pathResolutionCandidates() {
            let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedToken.isEmpty else { continue }

            let expandedToken = (normalizedToken as NSString).expandingTildeInPath
            let candidatePath: String
            if expandedToken.hasPrefix("/") {
                candidatePath = expandedToken
            } else {
                guard let cwd, !cwd.isEmpty else { continue }
                candidatePath = (cwd as NSString).appendingPathComponent(expandedToken)
            }

            let standardizedPath = (candidatePath as NSString).standardizingPath
            guard seenPaths.insert(standardizedPath).inserted else { continue }
            if fileExists(standardizedPath) {
                return standardizedPath
            }
        }

        return nil
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

    /// Resolves an open-URL request payload to an existing local file.
    ///
    /// The resolver tries the literal file spelling before interpreting a
    /// trailing `:line` or `:line:column` suffix. This keeps legitimate file
    /// names such as `report:42` addressable while still accepting the form
    /// emitted by compilers, test runners, and coding agents. Local `file://`
    /// URLs are accepted; URL schemes for remote or non-file resources are
    /// left to the URL router.
    ///
    /// - Parameters:
    ///   - rawText: The raw open-URL text from the runtime.
    ///   - cwd: The surface's working directory.
    /// - Returns: The first existing reference, or `nil`.
    public func resolveOpenURLFileReference(
        _ rawText: String,
        cwd: String?
    ) -> TerminalFileReference? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for token in trimmed.pathResolutionCandidates() {
            let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedToken.isEmpty else { continue }

            if let path = localFilePath(for: normalizedToken),
               let resolvedPath = resolveQuicklookPath(path, cwd: cwd) {
                return TerminalFileReference(path: resolvedPath)
            }

            guard let location = parseLocationSuffix(in: normalizedToken),
                  let path = localFilePath(for: location.path) else {
                continue
            }

            // A relative name such as `report:42` is parsed by Foundation as
            // a custom URL scheme. Once its suffix is known to be a location
            // and the location path itself is schemeless, probe the complete
            // spelling before treating it as `path:line`. This preserves a
            // real file named `report:42` without admitting non-file URLs.
            if !isExplicitFileURL(normalizedToken),
               let literalPath = resolveQuicklookPath(normalizedToken, cwd: cwd) {
                return TerminalFileReference(path: literalPath)
            }
            guard let resolvedPath = resolveQuicklookPath(path, cwd: cwd) else {
                continue
            }
            return TerminalFileReference(
                path: resolvedPath,
                line: location.line,
                column: location.column
            )
        }

        return nil
    }

    /// Resolves an open-URL request payload to an existing file path.
    ///
    /// Location information is intentionally discarded by this compatibility
    /// API. Call ``resolveOpenURLFileReference(_:cwd:)`` when the caller needs
    /// the source line or column.
    ///
    /// - Parameters:
    ///   - rawText: The raw open-URL text from the runtime.
    ///   - cwd: The surface's working directory.
    /// - Returns: The first existing standardized path, or `nil`.
    public func resolveOpenURLFilePath(_ rawText: String, cwd: String?) -> String? {
        resolveOpenURLFileReference(rawText, cwd: cwd)?.path
    }

    /// Converts a token into a local path while rejecting non-file URL schemes.
    private func localFilePath(for token: String) -> String? {
        guard let url = URL(string: token), let scheme = url.scheme else {
            return token
        }

        guard scheme.caseInsensitiveCompare("file") == .orderedSame else {
            return nil
        }
        guard url.host == nil || url.host?.isEmpty == true || url.host == "localhost" else {
            return nil
        }
        return url.path
    }

    /// Returns whether `token` is an explicit local `file` URL.
    private func isExplicitFileURL(_ token: String) -> Bool {
        URL(string: token)?.scheme?.caseInsensitiveCompare("file") == .orderedSame
    }

    /// Parses a positive `:line` or `:line:column` suffix from a token.
    private func parseLocationSuffix(
        in token: String
    ) -> (path: String, line: Int, column: Int?)? {
        guard let lastColon = token.lastIndex(of: ":") else { return nil }
        let lastComponent = String(token[token.index(after: lastColon)...])
        guard let lastNumber = positiveInteger(lastComponent) else { return nil }

        let pathEnd = lastColon
        let pathWithLine = String(token[..<pathEnd])
        guard let lineColon = pathWithLine.lastIndex(of: ":") else {
            return (pathWithLine, lastNumber, nil)
        }

        let lineComponent = String(pathWithLine[pathWithLine.index(after: lineColon)...])
        guard let lineNumber = positiveInteger(lineComponent) else {
            return (pathWithLine, lastNumber, nil)
        }

        let path = String(pathWithLine[..<lineColon])
        guard !path.isEmpty else { return nil }
        return (path, lineNumber, lastNumber)
    }

    /// Returns a positive integer for a valid source location component.
    private func positiveInteger(_ rawValue: String) -> Int? {
        guard let value = Int(rawValue), value > 0 else { return nil }
        return value
    }
}
