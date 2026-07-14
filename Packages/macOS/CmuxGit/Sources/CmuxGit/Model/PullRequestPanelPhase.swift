import Foundation

/// The complete loading and cached-error state machine for the pull-request panel.
public enum PullRequestPanelPhase: Equatable, Sendable {
    /// The panel has not resolved a workspace yet.
    case idle
    /// The first load is running and no cached content exists.
    case loading
    /// Fresh content is displayed.
    case loaded(PullRequestPanelContent)
    /// Cached content is displayed while a refresh runs.
    case refreshing(PullRequestPanelContent)
    /// Refresh failed; cached content remains attached when available.
    case failed(cached: PullRequestPanelContent?, error: PullRequestPanelServiceError)

    /// The content that should remain visible for the current phase.
    public var displayedContent: PullRequestPanelContent? {
        switch self {
        case .loaded(let content), .refreshing(let content): content
        case .failed(let cached, _): cached
        case .idle, .loading: nil
        }
    }

    /// Whether displayed content came from the latest successful refresh.
    public var isFresh: Bool {
        if case .loaded = self { return true }
        return false
    }

    /// Whether a GitHub refresh request is currently active.
    public var isRefreshInFlight: Bool {
        switch self {
        case .loading, .refreshing: true
        case .idle, .loaded, .failed: false
        }
    }
}
