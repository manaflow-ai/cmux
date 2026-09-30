public import Foundation

/// Input to `BrowserTabStateMachine`. Engines translate their native
/// callbacks (WKNavigationDelegate, KVO, CEF handlers) into these events.
public nonisolated enum BrowserNavigationEvent: Hashable, Sendable {
    case started(BrowserNavigationID, url: URL?)
    case redirected(BrowserNavigationID, url: URL?)
    case committed(BrowserNavigationID, url: URL?)
    case finished(BrowserNavigationID)
    case failed(BrowserNavigationID, BrowserLoadError)
    /// The user or the engine stopped the active load.
    case stopped
    case progress(Double)
    /// URL change without a navigation (pushState, fragment, KVO echo).
    case urlChanged(URL?)
    case titleChanged(String?)
    case historyChanged(canGoBack: Bool, canGoForward: Bool)
    case faviconChanged(URL?)
    case zoomChanged(Double)
    case contentFullscreenChanged(Bool)
    case securityChanged(BrowserSecurityState)
    /// The content process ended; the page is gone until the next load.
    case processExited(BrowserProcessExit)
    /// The content process stopped (true) or resumed (false) handling input.
    case unresponsiveChanged(Bool)
}

/// Pure reducer from engine events to `BrowserTabState`.
///
/// Rules that every engine gets for free:
/// - Callbacks for a navigation other than the active one are ignored, so a
///   late failure from a superseded load never overwrites the new load.
/// - Progress is clamped, never goes backwards within a navigation, and is
///   ignored when nothing is loading.
/// - Cancellation and download interruptions end the load without an error.
/// - Committing to another host clears the favicon and title.
/// - A process exit ends any load and marks the page gone; the next
///   navigation (Reload) clears it. A gone page is never unresponsive.
public nonisolated struct BrowserTabStateMachine: Sendable {
    /// Progress shown as soon as a navigation starts, so the bar is visible.
    public static let initialProgress = 0.1

    public private(set) var state: BrowserTabState

    /// URL of the last committed document. A load stopped before it commits
    /// reverts the address to this, like Chrome.
    private var committedURL: URL?

    public init(state: BrowserTabState = BrowserTabState()) {
        self.state = state
        self.committedURL = state.phase == .idle ? nil : state.url
    }

    /// Applies one event. Returns true when the state changed.
    @discardableResult
    public mutating func apply(_ event: BrowserNavigationEvent) -> Bool {
        let before = state
        reduce(event)
        return state != before
    }

    private mutating func reduce(_ event: BrowserNavigationEvent) {
        switch event {
        case .started(let id, let url):
            state.processExit = nil
            state.isUnresponsive = false
            state.activeNavigation = id
            state.phase = .provisional
            state.progress = Self.initialProgress
            if let url { state.url = url }

        case .redirected(let id, let url):
            guard id == state.activeNavigation, let url else { return }
            state.url = url

        case .committed(let id, let url):
            guard id == state.activeNavigation else { return }
            let previousHost = committedURL?.host()
            if let url { state.url = url }
            if state.url?.host() != previousHost {
                state.faviconURL = nil
            }
            state.title = nil
            state.phase = .committed
            state.security = Self.security(for: state.url)
            committedURL = state.url

        case .finished(let id):
            guard id == state.activeNavigation else { return }
            state.phase = .finished
            state.progress = 1
            state.activeNavigation = nil

        case .failed(let id, let error):
            guard id == state.activeNavigation else { return }
            if error.isBenignInterruption {
                endWithoutError()
            } else {
                state.phase = .failed(error)
                state.progress = 0
                state.activeNavigation = nil
            }

        case .stopped:
            guard state.isLoading else { return }
            endWithoutError()

        case .progress(let value):
            guard state.isLoading else { return }
            let clamped = min(max(value, 0), 1)
            state.progress = max(state.progress, clamped)

        case .urlChanged(let url):
            guard let url else { return }
            state.url = url
            if state.phase != .provisional {
                committedURL = url
            }
            if !state.isLoading {
                state.security = Self.security(for: url)
            }

        case .titleChanged(let title):
            let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            state.title = (trimmed?.isEmpty ?? true) ? nil : trimmed

        case .historyChanged(let back, let forward):
            state.canGoBack = back
            state.canGoForward = forward

        case .faviconChanged(let url):
            state.faviconURL = url

        case .zoomChanged(let zoom):
            state.zoom = BrowserZoom.clamp(zoom)

        case .contentFullscreenChanged(let on):
            state.isContentFullscreen = on

        case .securityChanged(let security):
            state.security = security

        case .processExited(let exit):
            // Keeps the URL even when the load had not committed, so Reload
            // opens what the user asked for.
            state.processExit = exit
            state.isUnresponsive = false
            state.progress = 0
            state.activeNavigation = nil
            if state.phase != .finished { state.phase = state.url == nil ? .idle : .finished }

        case .unresponsiveChanged(let unresponsive):
            guard state.processExit == nil else { return }
            state.isUnresponsive = unresponsive
        }
    }

    private mutating func endWithoutError() {
        if state.phase == .provisional {
            state.url = committedURL
            state.phase = committedURL == nil ? .idle : .finished
        } else {
            state.phase = .finished
        }
        state.progress = 0
        state.activeNavigation = nil
    }

    /// Scheme-level security. Engines refine it with `.securityChanged` when
    /// they know about mixed content or certificate problems.
    public static func security(for url: URL?) -> BrowserSecurityState {
        switch url?.scheme?.lowercased() {
        case "https": .secure
        case "http": .insecure
        case "file", "about", "data", "blob": .local
        default: .none
        }
    }
}
