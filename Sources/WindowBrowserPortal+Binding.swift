import AppKit
import Bonsplit
import ObjectiveC
import SwiftUI
import WebKit


// MARK: - Binding & synchronization scheduling
extension WindowBrowserPortal {
    func forceRefreshWebView(withId webViewId: ObjectIdentifier, reason: String) {
        guard ensureInstalled() else { return }
        let refreshSource = "forceRefresh:\(reason)"
        synchronizeWebView(
            withId: webViewId,
            source: refreshSource,
            forcePresentationRefresh: true
        )
        guard let entry = entriesByWebViewId[webViewId],
              let webView = entry.webView,
              let containerView = entry.containerView,
              !containerView.isHidden else {
            return
        }
        // Portal-host replacement/fullscreen churn relies on forceRefresh to kick
        // WebKit even when synchronizeWebView short-circuits or skips its refresh path.
        refreshHostedWebViewPresentation(
            webView,
            in: containerView,
            reason: refreshSource
        )
    }

    func bind(webView: WKWebView, to anchorView: NSView, visibleInUI: Bool, zPriority: Int = 0) {
        guard ensureInstalled() else { return }

        let webViewId = ObjectIdentifier(webView)
        let anchorId = ObjectIdentifier(anchorView)
        let previousEntry = entriesByWebViewId[webViewId]
        let shouldPreserveExternalFullscreenHost =
            webView.cmuxIsManagedByExternalFullscreenWindow(relativeTo: window)
        let containerView = ensureContainerView(
            for: previousEntry ?? Entry(
                webView: nil,
                containerView: nil,
                anchorView: nil,
                visibleInUI: false,
                zPriority: 0,
                dropZone: nil,
                paneDropContext: nil,
                searchOverlay: nil,
                omnibarSuggestions: nil,
                paneTopChromeHeight: 0,
                transientRecoveryReason: nil,
                transientRecoveryRetriesRemaining: 0
            ),
            webView: webView
        )

        if let previousWebViewId = webViewByAnchorId[anchorId], previousWebViewId != webViewId {
#if DEBUG
            let previousToken = entriesByWebViewId[previousWebViewId]
                .map { browserPortalDebugToken($0.webView) }
                ?? String(describing: previousWebViewId)
            cmuxDebugLog(
                "browser.portal.bind.replace anchor=\(browserPortalDebugToken(anchorView)) " +
                "oldWeb=\(previousToken) newWeb=\(browserPortalDebugToken(webView))"
            )
#endif
            detachWebView(withId: previousWebViewId)
        }

        if let oldEntry = entriesByWebViewId[webViewId],
           let oldAnchor = oldEntry.anchorView,
           oldAnchor !== anchorView {
            webViewByAnchorId.removeValue(forKey: ObjectIdentifier(oldAnchor))
        }

        webViewByAnchorId[anchorId] = webViewId
        entriesByWebViewId[webViewId] = Entry(
            webView: webView,
            containerView: containerView,
            anchorView: anchorView,
            visibleInUI: visibleInUI,
            zPriority: zPriority,
            dropZone: previousEntry?.dropZone,
            paneDropContext: previousEntry?.paneDropContext,
            searchOverlay: previousEntry?.searchOverlay,
            omnibarSuggestions: previousEntry?.omnibarSuggestions,
            paneTopChromeHeight: previousEntry?.paneTopChromeHeight ?? 0,
            transientRecoveryReason: previousEntry?.transientRecoveryReason,
            transientRecoveryRetriesRemaining: previousEntry?.transientRecoveryRetriesRemaining ?? 0
        )

        let didChangeAnchor: Bool = {
            guard let previousAnchor = previousEntry?.anchorView else { return true }
            return previousAnchor !== anchorView
        }()
        let becameVisible = (previousEntry?.visibleInUI ?? false) == false && visibleInUI
        let priorityIncreased = zPriority > (previousEntry?.zPriority ?? Int.min)
#if DEBUG
        if previousEntry == nil ||
            didChangeAnchor ||
            becameVisible ||
            priorityIncreased ||
            webView.superview !== containerView ||
            containerView.superview !== hostView {
            cmuxDebugLog(
                "browser.portal.bind web=\(browserPortalDebugToken(webView)) " +
                "container=\(browserPortalDebugToken(containerView)) " +
                "anchor=\(browserPortalDebugToken(anchorView)) prevAnchor=\(browserPortalDebugToken(previousEntry?.anchorView)) " +
                "visible=\(visibleInUI ? 1 : 0) prevVisible=\((previousEntry?.visibleInUI ?? false) ? 1 : 0) " +
                "z=\(zPriority) prevZ=\(previousEntry?.zPriority ?? Int.min)"
            )
        }
#endif

        if shouldPreserveExternalFullscreenHost {
#if DEBUG
            cmuxDebugLog(
                "browser.portal.reparent.skip web=\(browserPortalDebugToken(webView)) " +
                "reason=fullscreenExternalHost super=\(browserPortalDebugToken(webView.superview)) " +
                "container=\(browserPortalDebugToken(containerView)) " +
                "state=\(String(describing: webView.fullscreenState))"
            )
#endif
        } else if webView.superview !== containerView {
#if DEBUG
            cmuxDebugLog(
                "browser.portal.reparent web=\(browserPortalDebugToken(webView)) " +
                "reason=attachContainer super=\(browserPortalDebugToken(webView.superview)) " +
                "container=\(browserPortalDebugToken(containerView))"
            )
#endif
            if let sourceSuperview = webView.superview {
                moveWebKitRelatedSubviewsIfNeeded(
                    from: sourceSuperview,
                    to: containerView,
                    primaryWebView: webView,
                    reason: "bind.attachContainer"
                )
            } else {
                containerView.addSubview(webView, positioned: .above, relativeTo: nil)
            }
            containerView.pinHostedWebView(webView)
            webView.needsLayout = true
            webView.layoutSubtreeIfNeeded()
        } else {
            containerView.pinHostedWebView(webView)
        }

        if containerView.superview !== hostView {
#if DEBUG
            cmuxDebugLog(
                "browser.portal.reparent container=\(browserPortalDebugToken(containerView)) " +
                "reason=attach super=\(browserPortalDebugToken(containerView.superview))"
            )
#endif
            hostView.addSubview(containerView, positioned: .above, relativeTo: nil)
        } else if (becameVisible || priorityIncreased), hostView.subviews.last !== containerView {
#if DEBUG
            cmuxDebugLog(
                "browser.portal.reparent container=\(browserPortalDebugToken(containerView)) reason=raise " +
                "didChangeAnchor=\(didChangeAnchor ? 1 : 0) becameVisible=\(becameVisible ? 1 : 0) " +
                "priorityIncreased=\(priorityIncreased ? 1 : 0)"
            )
#endif
            hostView.addSubview(containerView, positioned: .above, relativeTo: nil)
        }

        synchronizeWebView(
            withId: webViewId,
            source: "bind",
            forcePresentationRefresh: didChangeAnchor
        )
        pruneDeadEntries()
    }

    func synchronizeWebViewForAnchor(_ anchorView: NSView) {
        pruneDeadEntries()
        let anchorId = ObjectIdentifier(anchorView)
        let primaryWebViewId = webViewByAnchorId[anchorId]
        if let primaryWebViewId {
            synchronizeWebView(withId: primaryWebViewId, source: "anchorPrimary")
        }

        // During rapid geometry changes (e.g. divider drag), syncing every web view
        // on every frame is expensive and causes stuttering.  Each panel's
        // HostContainerView fires its own geometry callback, so secondary web views
        // will sync themselves.  Defer the all-sync to coalesce with the next
        // run-loop turn instead.
        scheduleDeferredFullSynchronizeAll()
    }

    func scheduleDeferredFullSynchronizeAll() {
        guard !hasDeferredFullSyncScheduled else { return }
        hasDeferredFullSyncScheduled = true
#if DEBUG
        cmuxDebugLog("browser.portal.sync.defer.schedule entries=\(entriesByWebViewId.count)")
#endif
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasDeferredFullSyncScheduled = false
#if DEBUG
            cmuxDebugLog("browser.portal.sync.defer.tick entries=\(self.entriesByWebViewId.count)")
#endif
            self.synchronizeAllWebViews(excluding: nil, source: "deferredTick")
        }
    }

    func synchronizeAllWebViews(excluding webViewIdToSkip: ObjectIdentifier?, source: String) {
        guard ensureInstalled() else { return }
        pruneDeadEntries()
        let webViewIds = Array(entriesByWebViewId.keys)
        for webViewId in webViewIds {
            if webViewId == webViewIdToSkip { continue }
            synchronizeWebView(withId: webViewId, source: source)
        }
    }

    private func pruneDeadEntries() {
        let currentWindow = window
        let deadWebViewIds = entriesByWebViewId.compactMap { webViewId, entry -> ObjectIdentifier? in
            guard entry.webView != nil else { return webViewId }
            guard let container = entry.containerView else { return webViewId }
            guard let anchor = entry.anchorView else {
                // Workspace switching hides retiring browser portals before SwiftUI unmounts
                // their anchor views. Keep the hidden WKWebView/slot alive so switching back
                // can rebind the existing view instead of forcing a full WebKit reload.
                return nil
            }
            if container.superview == nil || !container.isDescendant(of: hostView) {
                return webViewId
            }
            let anchorInvalidForCurrentHost =
                anchor.window !== currentWindow ||
                anchor.superview == nil ||
                (installedReferenceView.map { !anchor.isDescendant(of: $0) } ?? false)
            if anchorInvalidForCurrentHost {
                // Hidden browser portals can legitimately be off-tree between workspace
                // deactivation and the next rebind. Preserve them until an explicit detach
                // (panel close, window teardown, or web view replacement) says otherwise.
                return nil
            }
            return nil
        }

        for webViewId in deadWebViewIds {
            detachWebView(withId: webViewId)
        }

        let validAnchorIds = Set(entriesByWebViewId.compactMap { _, entry in
            entry.anchorView.map { ObjectIdentifier($0) }
        })
        webViewByAnchorId = webViewByAnchorId.filter { validAnchorIds.contains($0.key) }
    }

}
