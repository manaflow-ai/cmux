import Foundation

/// Where a sidebar pull request link opens.
///
/// Sidebar pull request state always stores the canonical review-host URL the
/// probe reported; this selects what a click does with it. ``github`` keeps that
/// URL untouched, which is also what enterprise and non-GitHub hosts need.
///
/// ```swift
/// let configuration = PullRequestLinkConfiguration(destination: .graphite, customURLTemplate: "")
/// configuration.resolvedURL(for: canonicalURL)
/// ```
public enum PullRequestLinkDestination: String, CaseIterable, Identifiable, Sendable, SettingCodable {
    /// The pull request's own page on the host that reported it.
    case github

    /// The pull request in Graphite's review UI.
    case graphite

    /// A destination rendered from ``PullRequestLinkConfiguration/customURLTemplate``.
    case custom

    /// Stable identifier matching the stored raw value.
    public var id: String { rawValue }

    /// Localized display name shown in settings UI.
    public var displayName: String {
        switch self {
        case .github:
            return String(localized: "settings.sidebar.pullRequestLinkDestination.github", defaultValue: "GitHub")
        case .graphite:
            return String(localized: "settings.sidebar.pullRequestLinkDestination.graphite", defaultValue: "Graphite")
        case .custom:
            return String(localized: "settings.sidebar.pullRequestLinkDestination.custom", defaultValue: "Custom")
        }
    }

    /// URL template used to render links for this destination, or `nil` when the
    /// destination does not rewrite the canonical URL (``github``) or takes its
    /// template from settings (``custom``).
    public var urlTemplate: String? {
        switch self {
        case .github:
            return nil
        case .graphite:
            return "https://app.graphite.com/github/pr/{owner}/{repo}/{number}"
        case .custom:
            return nil
        }
    }
}
