public import CoreGraphics

/// Owns the page-zoom affordance for one `BrowserPanel`: the in/out/reset/set
/// commands and the clamp-and-fire-on-change apply step. Pure decision logic over
/// a ``BrowserZoomPolicy``; the only live effect, reading and writing the panel's
/// `WKWebView.pageZoom`, is forwarded to the app-side ``BrowserZoomHosting``.
///
/// Each command computes its target factor from the policy against the host's
/// live zoom (``BrowserZoomHosting/livePageZoom``), then ``applyPageZoom(_:)``
/// clamps it, skips the write when it is within `0.0001` of the current factor,
/// and otherwise writes it back, returning whether a change was applied.
///
/// `@MainActor` because `WKWebView.pageZoom` is main-actor-bound and the panel
/// that owns this coordinator is `@MainActor`, so every forward stays a plain
/// main-actor call.
@MainActor
public final class BrowserZoomCoordinator {
    /// The app-side host that owns the live `WKWebView.pageZoom`. Weak because the
    /// host (`BrowserPanel`) owns this coordinator strongly and outlives it, so
    /// this is non-nil whenever a method runs.
    public weak var host: (any BrowserZoomHosting)?

    /// The zoom bounds and per-step increment. Constructed with the defaults
    /// (0.25…5.0, step 0.1), matching the panel's prior inline policy.
    private let policy: BrowserZoomPolicy

    /// - Parameter policy: The zoom policy. Defaults to ``BrowserZoomPolicy()``.
    public init(policy: BrowserZoomPolicy = BrowserZoomPolicy()) {
        self.policy = policy
    }

    /// Zooms in one policy step from the live zoom. Returns whether the zoom
    /// changed (legacy `applyPageZoom(zoomPolicy.zoomedIn(from: webView.pageZoom))`).
    @discardableResult
    public func zoomIn() -> Bool {
        guard let host else { return false }
        return applyPageZoom(policy.zoomedIn(from: host.livePageZoom))
    }

    /// Zooms out one policy step from the live zoom. Returns whether the zoom
    /// changed (legacy `applyPageZoom(zoomPolicy.zoomedOut(from: webView.pageZoom))`).
    @discardableResult
    public func zoomOut() -> Bool {
        guard let host else { return false }
        return applyPageZoom(policy.zoomedOut(from: host.livePageZoom))
    }

    /// Resets the zoom to `1.0`. Returns whether the zoom changed (legacy
    /// `applyPageZoom(1.0)`).
    @discardableResult
    public func resetZoom() -> Bool {
        applyPageZoom(1.0)
    }

    /// The live page-zoom factor (legacy `webView.pageZoom`).
    public func currentPageZoomFactor() -> CGFloat {
        host?.livePageZoom ?? 1.0
    }

    /// Sets the page zoom to a clamped `pageZoom`. Returns whether the zoom
    /// changed (legacy `applyPageZoom(zoomPolicy.clamp(pageZoom))`).
    @discardableResult
    public func setPageZoomFactor(_ pageZoom: CGFloat) -> Bool {
        let clamped = policy.clamp(pageZoom)
        return applyPageZoom(clamped)
    }

    /// Clamps `candidate`, and if it differs from the live zoom by at least
    /// `0.0001`, writes it back through the host and returns `true`; otherwise
    /// returns `false` without writing (legacy private `applyPageZoom(_:)`).
    @discardableResult
    public func applyPageZoom(_ candidate: CGFloat) -> Bool {
        guard let host else { return false }
        let clamped = policy.clamp(candidate)
        if abs(host.livePageZoom - clamped) < 0.0001 {
            return false
        }
        host.livePageZoom = clamped
        return true
    }
}
