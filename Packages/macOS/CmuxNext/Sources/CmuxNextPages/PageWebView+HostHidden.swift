import CmuxNextHibernation
import CmuxNextWakeups
import WebKit

/// What a page view keeps to hide its WebKit view while its host is hidden
/// (``PageWebView/hidesWebKitWhenHostHidden``, feature `ownPagesHiddenToWebKit`).
@MainActor
final class PageHostHiddenState {
    /// The feature is on for this page.
    var enabled = false
    /// The WebKit view is hidden because the host is: the page's tab node says hidden.
    var hidesWebKit = false
    /// The node's flips and capture changes, while the page follows one.
    var subscriptions: [VisibilitySubscription] = []
    /// The node those subscriptions are on.
    weak var node: VisibilityNode?
}

// cmux's own pages hidden to WebKit (p14-energy-116). While the page's tab node is hidden (a parked
// tab, a hidden workspace, a miniaturized window) its WKWebView is hidden, so WebKit's page is hidden
// (`ActivityState::IsVisible`: `document.visibilityState` is `hidden`, rAF stops, hidden-page timer
// throttling applies). The view keeps its window and document and shows in the turn the node shows,
// with no reload: Chrome's `WebContentsImpl::UpdateWebContentsVisibility`
// (content/browser/web_contents/web_contents_impl.cc), `WasHidden` / `WasShown` per tab.
// A capture of the tab, sound, a media capture or WebRTC keep the page visible (Chrome's capturer
// count and `freezing_policy.cc`); occlusion stays WebKit's own call. A page shown in Chromium builds
// no WebKit view for this (``PageWebView/webKitPieces`` is read, never ``PageWebView/webKit``).
extension PageWebView {
    /// The keep reasons that hold a hidden page visible to WebKit.
    static let hostHiddenKeepsVisible: Set<PageKeepReasons.KeepReason> = [.audible, .capture, .webRTC]

    /// The page's WebKit view is hidden while its tab node is hidden (feature
    /// `ownPagesHiddenToWebKit`; ``WebUIHost`` sets it on each page it opens). Turning it off shows
    /// the view again in this turn.
    public var hidesWebKitWhenHostHidden: Bool {
        get { hostHidden.enabled }
        set {
            guard newValue != hostHidden.enabled else { return }
            hostHidden.enabled = newValue
            followHostVisibility()
        }
    }

    /// Whether the host hides the WebKit view now (tests and `debug.webui`).
    package var webKitHiddenByHost: Bool { hostHidden.hidesWebKit }

    /// Follows ``visibilityNode`` (its flips and its captures) while the feature is on, and applies
    /// what it says now. ``followAppearance(_:node:)`` calls it when the node changes.
    func followHostVisibility() {
        let node = hostHidden.enabled ? visibilityNode : nil
        if node !== hostHidden.node || hostHidden.subscriptions.isEmpty != (node == nil) {
            hostHidden.node = node
            hostHidden.subscriptions = node.map { node in
                [node.subscribe(owner: "PageWebView.hostHidden") { [weak self] _ in self?.applyHostVisibility() },
                 node.subscribeRendering(owner: "PageWebView.hostHidden") { [weak self] _ in self?.applyHostVisibility() }]
            } ?? []
        }
        applyHostVisibility()
    }

    /// Hides or shows the WebKit view by the host, in this turn. A view another owner hides (a
    /// Chromium page shows the document, the lifecycle froze or discarded the page) keeps its
    /// state: that owner shows it through ``revealWebKitView(_:)``, which reads this.
    func applyHostVisibility() {
        let hides = hostHidden.enabled && Self.hostHides(hostHidden.node, keepReasons: keepReasons.current)
        guard hides != hostHidden.hidesWebKit else { return }
        hostHidden.hidesWebKit = hides
        guard let view = webKitPieces?.view else { return }
        if hides {
            view.isHidden = true
        } else if webKitShowsDocument {
            view.isHidden = false
        }
    }

    /// Shows `view` as the WebKit engine's owner of the moment (a fallback, a thaw, a restore, a new
    /// engine) wants it shown, unless the host is hidden.
    func revealWebKitView(_ view: PageWKWebView) {
        view.isHidden = hostHidden.hidesWebKit
    }

    /// Whether WebKit shows the page's document now: no Chromium page shows it or is on its way, and
    /// the lifecycle has not frozen or discarded it.
    var webKitShowsDocument: Bool {
        chromiumSession == nil && engineDecision.engine != .cef && frozenEngine == nil && !isDiscarded
    }

    /// Whether a host whose tab node is `node` hides the page from WebKit: the node is hidden, not
    /// captured, and the page holds none of ``hostHiddenKeepsVisible``. No node: the host never said.
    static func hostHides(_ node: VisibilityNode?, keepReasons: Set<PageKeepReasons.KeepReason>) -> Bool {
        guard let node, node.effective == .hidden, !node.isCaptured else { return false }
        return keepReasons.isDisjoint(with: hostHiddenKeepsVisible)
    }
}
