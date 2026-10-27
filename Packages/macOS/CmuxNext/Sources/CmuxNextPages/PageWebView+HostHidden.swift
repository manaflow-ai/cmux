import CmuxNextDesign
import CmuxNextHibernation
import CmuxNextWakeups
import WebKit

/// What a page view keeps to hide its WebKit view while its host is hidden
/// (``PageWebView/hidesWebKitWhenHostHidden``, feature `ownPagesHiddenToWebKit`).
@MainActor
final class PageHostHiddenState {
    /// The feature is on for this page.
    var enabled = false
    /// The WebKit view is hidden because the host is: a node of the page's tab below its window says hidden.
    var hidesWebKit = false
    /// The tab node's flips and capture changes, and the window node's flips, while the page follows them.
    var subscriptions: [VisibilitySubscription] = []
    /// The tab node those subscriptions are on.
    weak var node: VisibilityNode?
    /// The node of the page's window (``WindowVisibilitySource``): a hide at it or above is WebKit's own.
    weak var windowNode: VisibilityNode?
}

// cmux's own pages hidden to WebKit (p14-energy-116). While the page's tab is hidden below its window
// (a parked tab, a hidden pane or workspace) its WKWebView is hidden, so WebKit's page is hidden
// (`ActivityState::IsVisible`: `document.visibilityState` is `hidden`, rAF stops, hidden-page timer
// throttling applies). The view keeps its window and document and shows in the turn the node shows,
// with no reload: Chrome's `WebContentsImpl::UpdateWebContentsVisibility`
// (content/browser/web_contents/web_contents_impl.cc), `WasHidden` / `WasShown` per tab.
// A miniaturized window, a hidden app and occlusion stay WebKit's own call: WebKit already hides the
// page through its window there, and hiding the view would move the window's first responder.
// A capture of the tab, sound or the page's media capture keep the page visible (Chrome's capturer
// count and `freezing_policy.cc`). A page the page lifecycle holds as shown hides only after the
// lifecycle's hide picture (``PageWebView/keepHideSnapshot(encoder:)``). A page shown in Chromium builds
// no WebKit view for this (``PageWebView/webKitPieces`` is read, never ``PageWebView/webKit``).
extension PageWebView {
    /// The keep reasons that hold a hidden page visible to WebKit: sound (``PageWebKitMediaWatch``) and
    /// the page's capture.
    static let hostHiddenKeepsVisible: Set<PageKeepReasons.KeepReason> = [.audible, .capture]

    /// The page's WebKit view is hidden while its tab node is hidden below its window (feature
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

    /// Follows ``visibilityNode`` (its flips and its captures) and its window's node (its flips) while
    /// the feature is on, and applies what they say now. ``followAppearance(_:node:)`` calls it when the
    /// node changes, `viewDidMoveToWindow` when the window does.
    func followHostVisibility() {
        let node = hostHidden.enabled ? visibilityNode : nil
        let windowNode = node == nil ? nil : window.flatMap { WindowVisibilitySource.installed(on: $0)?.node }
        if node !== hostHidden.node || windowNode !== hostHidden.windowNode || hostHidden.subscriptions.isEmpty != (node == nil) {
            hostHidden.node = node
            hostHidden.windowNode = windowNode
            var subscriptions: [VisibilitySubscription] = []
            if let node {
                subscriptions.append(node.subscribe(owner: "PageWebView.hostHidden") { [weak self] _ in self?.applyHostVisibility() })
                subscriptions.append(node.subscribeRendering(owner: "PageWebView.hostHidden") { [weak self] _ in self?.applyHostVisibility() })
            }
            // A tab switched while its window was miniaturized flips nothing; the window's show decides again.
            if let windowNode {
                subscriptions.append(windowNode.subscribe(owner: "PageWebView.hostHidden.window") { [weak self] _ in self?.applyHostVisibility() })
            }
            hostHidden.subscriptions = subscriptions
        }
        applyHostVisibility()
    }

    /// Hides or shows the WebKit view by the host, in this turn. A hide waits for the page lifecycle's
    /// hide picture when the lifecycle holds the page as shown: the tab's conceal pictures it first and
    /// calls this again (``keepHideSnapshot(encoder:)``). A view another owner hides (a Chromium page
    /// shows the document, the lifecycle froze or discarded the page) keeps its state: that owner shows
    /// it through ``revealWebKitView(_:)``, which reads this.
    func applyHostVisibility() {
        let hides = hostHidden.enabled
            && Self.hostHides(hostHidden.node, window: hostHidden.windowNode, keepReasons: keepReasons.current)
        guard hides != hostHidden.hidesWebKit else { return }
        if hides, keepReasons.lifecycle?.picturesNextHide(of: self) == true { return }
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

    /// Whether a host whose tab node is `node`, in the window whose node is `window`, hides the page
    /// from WebKit: the tab is hidden below its window, not captured, and the page holds none of
    /// ``hostHiddenKeepsVisible``. No node: the host never said.
    static func hostHides(_ node: VisibilityNode?, window: VisibilityNode?, keepReasons: Set<PageKeepReasons.KeepReason>) -> Bool {
        guard let node, node.effective == .hidden, !node.isCaptured else { return false }
        return keepReasons.isDisjoint(with: hostHiddenKeepsVisible) && ownHidden(from: node, below: window)
    }

    /// Whether `node` or an ancestor below `window` is own-hidden (a parked tab, a hidden pane or
    /// workspace). The walk stops at `window`, so a miniaturized window or a hidden app never counts; a
    /// tab no pane holds (under the unselected tabs' root) counts. O(tree depth).
    static func ownHidden(from node: VisibilityNode, below window: VisibilityNode?) -> Bool {
        var current: VisibilityNode? = node
        while let next = current, next !== window {
            if next.own == .hidden { return true }
            current = next.parent
        }
        return false
    }
}
