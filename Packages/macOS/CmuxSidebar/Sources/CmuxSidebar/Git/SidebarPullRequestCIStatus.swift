import Foundation

/// Rollup CI/check state shown next to an open pull-request row.
public enum SidebarPullRequestCIStatus: String, Sendable, Equatable {
    /// No rollup was fetched, checks are pending, no token is available, or no checks exist.
    case neutral
    /// The PR's latest commit checks passed.
    case success
    /// The PR's latest commit checks failed or errored.
    case failure

    /// SF Symbol used for the sidebar CI indicator.
    public var systemImageName: String {
        switch self {
        case .neutral: "minus.circle"
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        }
    }

    /// Localized tooltip for the sidebar CI indicator.
    public var localizedHelp: String {
        switch self {
        case .neutral:
            String(localized: "sidebar.ciStatus.pending", defaultValue: "CI checks pending")
        case .success:
            String(localized: "sidebar.ciStatus.success", defaultValue: "CI checks passed")
        case .failure:
            String(localized: "sidebar.ciStatus.failed", defaultValue: "CI checks failed")
        }
    }
}
