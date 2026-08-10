public import Foundation

/// Decides whether a terminal open-URL target may be handled by cmux's file UI.
public struct TerminalOpenURLFileRoutingPolicy: Sendable {
    /// Creates the file-routing policy.
    public init() {}

    /// Returns whether cmux may attempt to open the target in its file preview UI.
    ///
    /// The caller still owns settings, file existence, workspace locality, and
    /// split creation checks. This policy only answers whether the raw terminal
    /// open-URL payload represents a local file shape that cmux is allowed to
    /// intercept before the normal URL routing decision.
    ///
    /// - Parameters:
    ///   - rawOpenURLValue: The raw open-URL payload from the terminal runtime.
    ///   - target: The parsed terminal link target.
    public func shouldAttemptCmuxFileRouting(
        rawOpenURLValue: String,
        target: TerminalOpenURLTarget
    ) -> Bool {
        guard !Self.hasExplicitURLScheme(rawOpenURLValue) else { return false }
        guard target.url.isFileURL else { return false }
        return isLocalFileURL(target.url)
    }

    /// Returns whether the raw terminal open-URL payload looks like it was
    /// meant as a local filesystem path rather than a URL — even if this
    /// process ends up unable to resolve it to an existing file.
    ///
    /// Ghostty reports configured path-regex matches through the same
    /// `open_url` callback as URLs. If a relative path was printed before a
    /// file move/rename (or the terminal's cwd has since changed), treating
    /// something like `research/docs/report.md` as a bare host would
    /// incorrectly navigate to `https://research` — mismatched
    /// scheme-less wrapped-path fragments hit exactly this shape. Callers
    /// use this to consume (mark handled, open nothing) an unresolved local
    /// path intent instead of falling through to that misinterpretation.
    /// Domain-like first components, `localhost`, and any explicit scheme
    /// remain eligible for normal URL routing.
    public func isLikelyLocalPathReference(_ rawValue: String) -> Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !Self.hasExplicitURLScheme(trimmed) else { return false }

        if (trimmed as NSString).isAbsolutePath ||
            trimmed.hasPrefix("./") ||
            trimmed.hasPrefix("../") ||
            trimmed.hasPrefix("~/") {
            return true
        }

        guard let slash = trimmed.firstIndex(of: "/") else { return false }
        let firstComponent = String(trimmed[..<slash]).lowercased()
        guard !firstComponent.isEmpty else { return false }
        guard firstComponent != "localhost" else { return false }
        guard !firstComponent.contains(".") else { return false }
        guard !firstComponent.contains(":") else { return false }
        guard !firstComponent.contains("@") else { return false }
        return true
    }

    /// Returns whether the trimmed raw callback value contains a non-empty URL
    /// scheme. All terminal URL-routing paths use this same predicate.
    public static func hasExplicitURLScheme(_ rawValue: String) -> Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = URL(string: trimmed)?.scheme else { return false }
        return !scheme.isEmpty
    }

    private func isLocalFileURL(_ url: URL) -> Bool {
        url.host?.isEmpty ?? true
    }
}
