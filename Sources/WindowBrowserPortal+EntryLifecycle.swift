import AppKit
import Bonsplit
import ObjectiveC
import SwiftUI
import WebKit


// MARK: - Entry lifecycle
extension WindowBrowserPortal {
    func detachWebView(withId webViewId: ObjectIdentifier) {
        cancelPendingHostedWebViewRefreshes(for: webViewId)
        guard let entry = entriesByWebViewId.removeValue(forKey: webViewId) else { return }
        if let anchor = entry.anchorView {
            webViewByAnchorId.removeValue(forKey: ObjectIdentifier(anchor))
        }
#if DEBUG
        let hadContainerSuperview = (entry.containerView?.superview === hostView) ? 1 : 0
        let hadWebSuperview = entry.webView?.superview == nil ? 0 : 1
        cmuxDebugLog(
            "browser.portal.detach web=\(browserPortalDebugToken(entry.webView)) " +
            "container=\(browserPortalDebugToken(entry.containerView)) " +
            "anchor=\(browserPortalDebugToken(entry.anchorView)) " +
            "hadContainerSuperview=\(hadContainerSuperview) hadWebSuperview=\(hadWebSuperview)"
        )
#endif
        if let webView = entry.webView, let containerView = entry.containerView {
            notifyHostedWebKitHidden(
                in: containerView,
                primaryWebView: webView,
                reason: "detach"
            )
        } else {
            entry.webView?.browserPortalNotifyHidden(reason: "detach")
        }
        entry.webView?.removeFromSuperview()
        entry.containerView?.removeFromSuperview()
    }

    func discardWebViewEntry(
        withId webViewId: ObjectIdentifier,
        source: String,
        preserveCurrentSuperview: Bool
    ) {
        cancelPendingHostedWebViewRefreshes(for: webViewId)
        guard let entry = entriesByWebViewId.removeValue(forKey: webViewId) else { return }
        if let anchor = entry.anchorView {
            webViewByAnchorId.removeValue(forKey: ObjectIdentifier(anchor))
        }

        let portalOwnsWebView = entry.webView?.superview === entry.containerView
#if DEBUG
        cmuxDebugLog(
            "browser.portal.discard web=\(browserPortalDebugToken(entry.webView)) " +
            "container=\(browserPortalDebugToken(entry.containerView)) " +
            "anchor=\(browserPortalDebugToken(entry.anchorView)) " +
            "source=\(source) preserve=\(preserveCurrentSuperview ? 1 : 0) " +
            "portalOwnsWeb=\(portalOwnsWebView ? 1 : 0) " +
            "currentSuper=\(browserPortalDebugToken(entry.webView?.superview))"
        )
#endif

        if !(preserveCurrentSuperview && !portalOwnsWebView) {
            if let webView = entry.webView, let containerView = entry.containerView {
                notifyHostedWebKitHidden(
                    in: containerView,
                    primaryWebView: webView,
                    reason: "discard:\(source)"
                )
            } else {
                entry.webView?.browserPortalNotifyHidden(reason: "discard:\(source)")
            }
            entry.webView?.removeFromSuperview()
        }
        entry.containerView?.removeFromSuperview()
    }

    /// Update the visibleInUI/zPriority state on an existing entry without rebinding.
    /// Used when a bind is deferred (host not yet in window) so stale portal syncs
    /// do not keep an old anchor visible.
    func updateEntryVisibility(forWebViewId webViewId: ObjectIdentifier, visibleInUI: Bool, zPriority: Int) {
        guard var entry = entriesByWebViewId[webViewId] else { return }
        guard entry.visibleInUI != visibleInUI || entry.zPriority != zPriority else { return }
        entry.visibleInUI = visibleInUI
        entry.zPriority = zPriority
        entriesByWebViewId[webViewId] = entry
    }

    func isWebViewBoundToAnchor(withId webViewId: ObjectIdentifier, anchorView: NSView) -> Bool {
        guard let entry = entriesByWebViewId[webViewId],
              let boundAnchor = entry.anchorView else { return false }
        return boundAnchor === anchorView
    }

    func hideWebView(withId webViewId: ObjectIdentifier, source: String = "externalHide") {
        guard var entry = entriesByWebViewId[webViewId] else { return }
        entry.visibleInUI = false
        entry.zPriority = 0
        entriesByWebViewId[webViewId] = entry
        synchronizeWebView(withId: webViewId, source: source)
    }

    func webViewIds() -> Set<ObjectIdentifier> {
        Set(entriesByWebViewId.keys)
    }

    func tearDown() {
        removeGeometryObservers()
        for webViewId in Array(entriesByWebViewId.keys) {
            detachWebView(withId: webViewId)
        }
        hostView.removeFromSuperview()
        installedContainerView = nil
        installedReferenceView = nil
    }

}
