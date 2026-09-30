public import Foundation

/// Resolves macOS browser omnibar text into a URL that can be loaded directly.
///
/// Search-engine fallback remains the caller's responsibility. The resolver
/// handles explicit web/file URLs, bare POSIX or tilde paths, local development
/// hosts, and scheme-less hosts after canonicalizing line breaks introduced by
/// wrapped pastes.
public struct BrowserURLResolver: Sendable {
    private let homeDirectoryURL: URL

    /// Creates a browser URL resolver.
    ///
    /// - Parameter homeDirectoryURL: The home directory used to expand `~` paths.
    ///   Production callers use the current user's home directory; tests can
    ///   provide a stable URL without consulting the process environment.
    public init(homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectoryURL = homeDirectoryURL
    }

    /// Prepares raw pasteboard text for insertion into a single-line omnibar.
    ///
    /// AppKit replaces pasted line breaks with spaces before the field value is
    /// submitted. This method removes terminal-wrap line breaks and tabs only
    /// when the compacted text is a navigable URL, preserving ordinary spaces
    /// and free-text searches exactly as pasted.
    ///
    /// - Parameter input: Raw string content read from the pasteboard.
    /// - Returns: URL text with safe wrap artifacts removed, or `input` unchanged.
    public func textForPaste(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let prepared = canonicalNavigationText(trimmed)
        return prepared == trimmed ? input : prepared
    }

    /// Resolves submitted address text into a directly navigable URL.
    ///
    /// - Parameter input: Raw text submitted by the omnibar or another browser entrypoint.
    /// - Returns: A navigable URL, or `nil` when the text should be treated as a search query.
    public func navigableURL(from input: String) -> URL? {
        let trimmed = canonicalNavigationText(
            input.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains(where: { $0.isNewline || $0 == "\t" }) else { return nil }
        if let url = explicitURL(from: trimmed) {
            return url
        }
        if let url = localFileURL(from: trimmed) {
            return url
        }
        guard !hasSchemeLessUserInfo(in: trimmed) else { return nil }
        guard !trimmed.contains(where: \.isWhitespace) else { return nil }

        let lower = trimmed.lowercased()
        let bareHost = bareHostCandidate(lower)
        if BrowserAppWebOrigin.isLoopbackHost(bareHost) {
            return URL(string: "http://\(trimmed)")
        }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            if scheme == "file", url.isFileURL, url.path.hasPrefix("/") {
                return url
            }
            if isDottedHostWithPort(trimmed, schemeCandidate: scheme) {
                return URL(string: "https://\(trimmed)")
            }
            return nil
        }

        if trimmed.contains(":") || trimmed.contains("/") || trimmed.contains(".") {
            return URL(string: "https://\(trimmed)")
        }
        return nil
    }

    /// Returns a URL for an explicit scheme already present in the input.
    ///
    /// The omnibar intentionally keeps its existing web/file allowlist: other
    /// schemes are handled by the browser's external-navigation paths rather
    /// than being loaded as typed omnibar destinations.
    private func explicitURL(from input: String) -> URL? {
        guard let url = URL(string: input),
              let scheme = url.scheme?.lowercased() else {
            return nil
        }

        switch scheme {
        case "http", "https":
            return webURL(from: input)
        case "file":
            guard url.isFileURL, url.path.hasPrefix("/") else { return nil }
            return url
        default:
            return nil
        }
    }

    /// Converts a syntactically local absolute path into a file URL.
    private func localFileURL(from input: String) -> URL? {
        let path: String
        if input.hasPrefix("/") {
            path = input
        } else if input == "~" {
            path = homeDirectoryURL.path
        } else if input.hasPrefix("~/"), homeDirectoryURL.path.hasPrefix("/") {
            path = homeDirectoryURL
                .appending(path: String(input.dropFirst(2)))
                .path
        } else {
            return nil
        }

        return URL(fileURLWithPath: path)
    }

    private func canonicalNavigationText(_ trimmed: String) -> String {
        let compacted = trimmed.filter { !$0.isNewline && $0 != "\t" }
        guard compacted != trimmed,
              isWhitespaceCompactionSafe(compacted, original: trimmed) else {
            return trimmed
        }
        return compacted
    }

    private func isWhitespaceCompactionSafe(_ compacted: String, original: String) -> Bool {
        guard !compacted.isEmpty else { return false }
        if isWebURL(compacted) {
            return hasCompleteWebAuthorityBeforeFirstCompactedCharacter(in: original)
        }
        guard hasCompleteSchemeLessAuthorityBeforeFirstCompactedCharacter(in: original) else { return false }
        return isSchemeLessHostWithStructure(compacted)
    }

    /// Allows wrap removal only after the explicit URL's authority is complete.
    private func hasCompleteWebAuthorityBeforeFirstCompactedCharacter(in input: String) -> Bool {
        guard let compactedCharacter = input.firstIndex(where: { $0.isNewline || $0 == "\t" }),
              let schemeSeparator = input.range(of: "://"),
              schemeSeparator.upperBound < compactedCharacter else {
            return false
        }
        guard let authorityEnd = input[schemeSeparator.upperBound...].firstIndex(where: { character in
            character == "/" || character == "?" || character == "#"
        }) else {
            return false
        }
        return authorityEnd < compactedCharacter
    }

    /// Allows scheme-less wrap removal only after the authority is complete.
    private func hasCompleteSchemeLessAuthorityBeforeFirstCompactedCharacter(in input: String) -> Bool {
        guard let compactedCharacter = input.firstIndex(where: { $0.isNewline || $0 == "\t" }),
              let authorityEnd = input.firstIndex(where: { character in
                  character == "/" || character == "?" || character == "#"
              }) else {
            return false
        }
        return authorityEnd < compactedCharacter
    }

    private func isWebURL(_ input: String) -> Bool {
        webURL(from: input) != nil
    }

    private func webURL(from input: String) -> URL? {
        guard hasWhitespaceFreeAuthority(in: input),
              let components = URLComponents(string: input),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else {
            return nil
        }
        return components.url
    }

    /// Rejects whitespace that Foundation would otherwise encode inside URL userinfo.
    private func hasWhitespaceFreeAuthority(in input: String) -> Bool {
        guard let schemeSeparator = input.range(of: "://") else { return false }
        let authority = input[schemeSeparator.upperBound...].prefix { character in
            character != "/" && character != "?" && character != "#"
        }
        return !authority.isEmpty && !authority.contains(where: \.isWhitespace)
    }

    /// Rejects scheme-less userinfo while allowing `@` in paths and queries.
    private func hasSchemeLessUserInfo(in input: String) -> Bool {
        guard !input.contains("://") else { return false }
        let authority = input.prefix { character in
            character != "/" && character != "?" && character != "#"
        }
        return authority.contains("@")
    }

    private func isSchemeLessHostWithStructure(_ input: String) -> Bool {
        guard !input.contains("://"),
              let components = URLComponents(string: "https://\(input)"),
              let host = components.host,
              !host.isEmpty else {
            return false
        }

        let isHostLike = host == "localhost" ||
            host.hasSuffix(".localhost") ||
            host.contains(".") ||
            host.contains(":")
        guard isHostLike else { return false }

        let hasPathQueryOrFragment = !components.path.isEmpty ||
            components.query != nil ||
            components.fragment != nil
        return hasPathQueryOrFragment || components.port != nil
    }

    private func bareHostCandidate(_ lowercasedInput: String) -> String {
        if lowercasedInput.hasPrefix("["),
           let closingBracket = lowercasedInput.firstIndex(of: "]") {
            return String(lowercasedInput[lowercasedInput.index(after: lowercasedInput.startIndex)..<closingBracket])
        }
        let end = lowercasedInput.firstIndex { character in
            character == ":" || character == "/" || character == "?" || character == "#"
        } ?? lowercasedInput.endIndex
        return String(lowercasedInput[..<end])
    }

    private func isDottedHostWithPort(_ input: String, schemeCandidate: String) -> Bool {
        guard schemeCandidate.contains(".") else { return false }
        guard input.count > schemeCandidate.count else { return false }
        let afterScheme = input.dropFirst(schemeCandidate.count)
        guard afterScheme.first == ":" else { return false }
        let portAndRest = afterScheme.dropFirst()
        let port = portAndRest.prefix(while: { $0.isNumber })
        guard !port.isEmpty, UInt16(port) != nil else { return false }
        let rest = portAndRest.dropFirst(port.count)
        return rest.isEmpty || rest.first == "/" || rest.first == "?" || rest.first == "#"
    }
}
