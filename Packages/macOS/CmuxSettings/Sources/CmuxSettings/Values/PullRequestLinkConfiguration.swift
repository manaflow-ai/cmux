import Foundation

/// Resolved pull request link settings used wherever cmux opens a sidebar
/// pull request.
///
/// Sidebar state keeps the canonical URL the review host reported; this type is
/// the single seam that rewrites it at open time, so polling, deduplication, and
/// staleness comparisons keep working on the canonical value.
///
/// ```swift
/// let configuration = PullRequestLinkConfiguration(destination: .graphite, customURLTemplate: "")
/// configuration.resolvedURL(for: URL(string: "https://github.com/manaflow-ai/cmux/pull/9641")!)
/// // https://app.graphite.com/github/pr/manaflow-ai/cmux/9641
/// ```
public struct PullRequestLinkConfiguration: Equatable, Sendable {
    /// Destination applied when no preference is stored.
    public static let defaultDestination: PullRequestLinkDestination = .github

    /// Custom template applied when no preference is stored. Empty means links
    /// open unchanged, matching ``PullRequestLinkDestination/github``.
    public static let defaultCustomURLTemplate = ""

    /// The selected destination.
    public let destination: PullRequestLinkDestination

    /// The stored custom URL template, used only when ``destination`` is
    /// ``PullRequestLinkDestination/custom``.
    public let customURLTemplate: String

    /// Creates a resolved pull request link configuration.
    ///
    /// - Parameters:
    ///   - destination: The selected destination.
    ///   - customURLTemplate: The custom URL template.
    public init(destination: PullRequestLinkDestination, customURLTemplate: String) {
        self.destination = destination
        self.customURLTemplate = customURLTemplate
    }

    /// The template this configuration renders, or `nil` when links open unchanged.
    public var urlTemplate: String? {
        guard destination == .custom else { return destination.urlTemplate }
        let trimmed = customURLTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Rewrites a canonical pull request URL for the configured destination.
    ///
    /// - Parameter canonicalURL: The URL the review host reported for the pull request.
    /// - Returns: The rewritten URL, or `canonicalURL` unchanged when the
    ///   destination does not rewrite links, the URL is not a recognizable pull
    ///   request URL (an enterprise path shape, a permalink to a comment), or the
    ///   configured template cannot produce an `http`/`https` URL.
    public func resolvedURL(for canonicalURL: URL) -> URL {
        guard let template = urlTemplate,
              let reference = PullRequestLinkReference(pullRequestURL: canonicalURL),
              let rendered = Self.url(fromTemplate: template, reference: reference) else {
            return canonicalURL
        }
        return rendered
    }

    /// Whether a template renders an allowed URL, for validating settings input.
    ///
    /// - Parameter rawTemplate: The template to check. Empty templates are valid
    ///   and mean links open unchanged.
    /// - Returns: `true` when the template is empty or renders an `http`/`https` URL.
    public static func isValidURLTemplate(_ rawTemplate: String) -> Bool {
        let trimmed = rawTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return url(
            fromTemplate: trimmed,
            reference: PullRequestLinkReference(owner: "manaflow-ai", repo: "cmux", number: 1)
        ) != nil
    }

    /// Renders a pull request URL from a template.
    ///
    /// - Parameters:
    ///   - rawTemplate: A template containing `{owner}`, `{repo}`, and `{number}`
    ///     placeholders. A template with no placeholder cannot address a specific
    ///     pull request and is rejected.
    ///   - reference: The pull request to render.
    /// - Returns: An allowed `http` or `https` URL, or `nil` when the template
    ///   cannot produce one.
    public static func url(fromTemplate rawTemplate: String, reference: PullRequestLinkReference) -> URL? {
        let template = rawTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard template.contains("{number}") else { return nil }
        let rendered = template
            .replacingOccurrences(of: "{owner}", with: percentEncoded(reference.owner))
            .replacingOccurrences(of: "{repo}", with: percentEncoded(reference.repo))
            .replacingOccurrences(of: "{number}", with: String(reference.number))
        guard let url = URL(string: rendered),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    private static func percentEncoded(_ segment: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }
}
