public import Foundation

/// Resolves macOS browser omnibar text into a URL that can be loaded directly.
///
/// Search-engine fallback remains the caller's responsibility. The resolver
/// handles web URLs, local development hosts, scheme-less hosts, and absolute
/// file URLs after canonicalizing whitespace introduced by wrapped pastes.
public struct BrowserURLResolver: Sendable {
    /// Creates a browser URL resolver.
    public init() {}

    /// Resolves submitted address text into a directly navigable URL.
    ///
    /// - Parameter input: Raw text submitted by the omnibar or another browser entrypoint.
    /// - Returns: A navigable URL, or `nil` when the text should be treated as a search query.
    public func navigableURL(from input: String) -> URL? {
        let trimmed = canonicalNavigationText(
            input.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains(where: \.isWhitespace) else { return nil }

        let lower = trimmed.lowercased()
        let bareHost = bareHostCandidate(lower)
        if lower.hasPrefix("localhost") ||
            lower.hasPrefix("127.0.0.1") ||
            lower.hasPrefix("[::1]") ||
            (bareHost != ".localhost" && bareHost.hasSuffix(".localhost")) {
            return URL(string: "http://\(trimmed)")
        }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" {
                return url
            }
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

    private func canonicalNavigationText(_ trimmed: String) -> String {
        let compacted = trimmed.filter { !$0.isWhitespace }
        guard compacted != trimmed, isWhitespaceCompactionSafe(compacted) else {
            return trimmed
        }
        return compacted
    }

    private func isWhitespaceCompactionSafe(_ compacted: String) -> Bool {
        guard !compacted.isEmpty else { return false }
        if isWebURL(compacted) {
            return true
        }
        return isSchemeLessHostWithStructure(compacted)
    }

    private func isWebURL(_ input: String) -> Bool {
        guard let components = URLComponents(string: input),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else {
            return false
        }
        return true
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
