import AppKit
import Bonsplit
import ObjectiveC
import SwiftUI
import WebKit


// MARK: - Hosted WebKit subview management & refresh passes
extension WindowBrowserPortal {
    private func directTransferChild(of container: NSView, containing descendant: NSView) -> NSView? {
        var current: NSView? = descendant
        var directChild: NSView?
        while let view = current, view !== container {
            directChild = view
            current = view.superview
        }
        guard current === container else { return nil }
        return directChild
    }

    private func relatedWebKitTransferSubviews(
        from sourceSuperview: NSView,
        primaryWebView: WKWebView
    ) -> [NSView] {
        var relatedSubviews: [NSView] = []
        var seen = Set<ObjectIdentifier>()

        func append(_ candidate: NSView?) {
            guard let candidate, candidate !== sourceSuperview else { return }
            let id = ObjectIdentifier(candidate)
            guard seen.insert(id).inserted else { return }
            relatedSubviews.append(candidate)
        }

        // The Web Inspector frontend is owned by WebKit's inspector window/controller.
        // Moving it into the portal can leave WebKit window observers pointing at a
        // stale host during user-initiated inspector-window close.
        let primaryTransferView = directTransferChild(of: sourceSuperview, containing: primaryWebView) ?? primaryWebView
        if Self.containsInspectorView(in: primaryTransferView) {
            append(primaryWebView)
        } else {
            append(primaryTransferView)
        }

        for view in sourceSuperview.subviews {
            if view === primaryWebView { continue }
            let className = String(describing: type(of: view))
            if cmuxIsWebInspectorClassName(className) || Self.containsInspectorView(in: view) {
                continue
            }
            guard className.contains("WK") else { continue }
            append(view)
        }

        return relatedSubviews
    }

    private static func containsInspectorView(in root: NSView) -> Bool {
        var stack: [NSView] = [root]
        while let current = stack.popLast() {
            if cmuxIsWebInspectorObject(current) {
                return true
            }
            stack.append(contentsOf: current.subviews)
        }
        return false
    }

    private func appendHostedWebKitSubviews(
        in root: NSView,
        to result: inout [WKWebView],
        seen: inout Set<ObjectIdentifier>
    ) {
        if let webView = root as? WKWebView {
            guard !Self.isInspectorFrontendWebView(webView) else { return }
            let id = ObjectIdentifier(webView)
            if seen.insert(id).inserted {
                result.append(webView)
            }
        }
        for subview in root.subviews {
            appendHostedWebKitSubviews(in: subview, to: &result, seen: &seen)
        }
    }

    private func hostedWebKitSubviews(
        in containerView: NSView,
        primaryWebView: WKWebView
    ) -> [WKWebView] {
        var result: [WKWebView] = []
        var seen = Set<ObjectIdentifier>()

        func append(_ webView: WKWebView?) {
            guard let webView else { return }
            guard !Self.isInspectorFrontendWebView(webView) else { return }
            let id = ObjectIdentifier(webView)
            guard seen.insert(id).inserted else { return }
            result.append(webView)
        }

        if primaryWebView === containerView ||
            primaryWebView.superview === containerView ||
            primaryWebView.isDescendant(of: containerView) {
            append(primaryWebView)
        }
        appendHostedWebKitSubviews(in: containerView, to: &result, seen: &seen)
        return result
    }

    private static func isInspectorFrontendWebView(_ webView: WKWebView) -> Bool {
        cmuxIsWebInspectorObject(webView)
    }

    func notifyHostedWebKitHidden(
        in containerView: NSView,
        primaryWebView: WKWebView,
        reason: String
    ) {
        for webKitSubview in hostedWebKitSubviews(
            in: containerView,
            primaryWebView: primaryWebView
        ) {
            webKitSubview.browserPortalNotifyHidden(reason: reason)
        }
    }

    func ensureContainerView(for entry: Entry, webView: WKWebView) -> WindowBrowserSlotView {
        if let existing = entry.containerView {
            existing.setPaneDropContext(entry.paneDropContext)
            existing.setSearchOverlay(entry.searchOverlay)
            existing.setOmnibarSuggestions(entry.omnibarSuggestions)
            existing.setPaneTopChromeHeight(entry.paneTopChromeHeight)
            return existing
        }
        let created = WindowBrowserSlotView(frame: .zero)
        created.setPaneDropContext(entry.paneDropContext)
        created.setSearchOverlay(entry.searchOverlay)
        created.setOmnibarSuggestions(entry.omnibarSuggestions)
        created.setPaneTopChromeHeight(entry.paneTopChromeHeight)
#if DEBUG
        cmuxDebugLog(
            "browser.portal.container.create web=\(browserPortalDebugToken(webView)) " +
            "container=\(browserPortalDebugToken(created))"
        )
#endif
        return created
    }

    private func runHostedWebViewRefreshPass(
        _ webView: WKWebView,
        in containerView: WindowBrowserSlotView,
        reason: String,
        phase: String,
        reattachRenderingState: Bool
    ) {
        guard !containerView.isHidden else { return }
        guard !containerView.isHostedInspectorDividerDragActive else {
#if DEBUG
            cmuxDebugLog(
                "browser.portal.refresh.skip web=\(browserPortalDebugToken(webView)) " +
                "container=\(browserPortalDebugToken(containerView)) reason=\(reason) phase=\(phase) " +
                "drag=1 reattach=\(reattachRenderingState ? 1 : 0)"
            )
#endif
            return
        }

        let hostedWebKitSubviews = hostedWebKitSubviews(
            in: containerView,
            primaryWebView: webView
        )
        guard !hostedWebKitSubviews.isEmpty else { return }

        containerView.needsLayout = true
        containerView.needsDisplay = true
        containerView.setNeedsDisplay(containerView.bounds)

        for webKitSubview in hostedWebKitSubviews {
            if let scrollView = webKitSubview.enclosingScrollView {
                scrollView.needsLayout = true
                scrollView.needsDisplay = true
                scrollView.setNeedsDisplay(scrollView.bounds)
                scrollView.contentView.needsLayout = true
                scrollView.contentView.needsDisplay = true
            }

            webKitSubview.needsLayout = true
            webKitSubview.needsDisplay = true
            webKitSubview.setNeedsDisplay(webKitSubview.bounds)
        }

        containerView.layoutSubtreeIfNeeded()
        for webKitSubview in hostedWebKitSubviews {
            if let scrollView = webKitSubview.enclosingScrollView {
                scrollView.layoutSubtreeIfNeeded()
                scrollView.contentView.layoutSubtreeIfNeeded()
                scrollView.displayIfNeeded()
            }
            webKitSubview.layoutSubtreeIfNeeded()
            if reattachRenderingState {
                webKitSubview.browserPortalReattachRenderingState(reason: "\(reason):\(phase)")
            }
            webKitSubview.displayIfNeeded()
        }
        containerView.displayIfNeeded()
        (containerView.window ?? webView.window ?? hostView.window)?.displayIfNeeded()
#if DEBUG
        cmuxDebugLog(
            "\(reattachRenderingState ? "browser.portal.refresh" : "browser.portal.invalidate") " +
            "web=\(browserPortalDebugToken(webView)) " +
            "container=\(browserPortalDebugToken(containerView)) reason=\(reason) " +
            "phase=\(phase) frame=\(browserPortalDebugFrame(containerView.frame))"
        )
#endif
    }

    func cancelPendingHostedWebViewRefreshes(
        for webViewId: ObjectIdentifier,
        keepGeneration: Bool = false
    ) {
        guard var pending = pendingHostedWebViewRefreshes[webViewId] else { return }
        pending.asyncWorkItem?.cancel()
        pending.delayedWorkItem?.cancel()
        if keepGeneration {
            pending.asyncWorkItem = nil
            pending.delayedWorkItem = nil
            pendingHostedWebViewRefreshes[webViewId] = pending
        } else {
            pendingHostedWebViewRefreshes.removeValue(forKey: webViewId)
        }
    }

    func invalidateHostedWebViewGeometry(
        _ webView: WKWebView,
        in containerView: WindowBrowserSlotView,
        reason: String
    ) {
        runHostedWebViewRefreshPass(
            webView,
            in: containerView,
            reason: reason,
            phase: "geometry",
            reattachRenderingState: false
        )
    }

    func refreshHostedWebViewPresentation(
        _ webView: WKWebView,
        in containerView: WindowBrowserSlotView,
        reason: String
    ) {
        guard !containerView.isHidden else { return }
        let webViewId = ObjectIdentifier(webView)

        // Bind/reveal/fullscreen refreshes can stack up during a single layout churn.
        // Keep only the latest follow-up passes so reattach work does not pile up on
        // the main thread while browser panes are moving between hosts.
        cancelPendingHostedWebViewRefreshes(for: webViewId, keepGeneration: true)
        var pending = pendingHostedWebViewRefreshes[webViewId] ?? PendingHostedWebViewRefresh()
        nextHostedWebViewRefreshGeneration &+= 1
        let generation = nextHostedWebViewRefreshGeneration
        pending.generation = generation

        runHostedWebViewRefreshPass(
            webView,
            in: containerView,
            reason: reason,
            phase: "immediate",
            reattachRenderingState: true
        )

        let asyncWorkItem = DispatchWorkItem { [weak self, weak webView, weak containerView] in
            guard let self, let webView, let containerView else { return }
            guard self.pendingHostedWebViewRefreshes[webViewId]?.generation == generation else { return }
            self.runHostedWebViewRefreshPass(
                webView,
                in: containerView,
                reason: reason,
                phase: "async",
                reattachRenderingState: true
            )
        }
        pending.asyncWorkItem = asyncWorkItem

        let delayedWorkItem = DispatchWorkItem { [weak self, weak webView, weak containerView] in
            guard let self else { return }
            defer {
                if var current = self.pendingHostedWebViewRefreshes[webViewId],
                   current.generation == generation {
                    current.asyncWorkItem = nil
                    current.delayedWorkItem = nil
                    self.pendingHostedWebViewRefreshes[webViewId] = current
                }
            }
            guard let webView, let containerView else { return }
            guard self.pendingHostedWebViewRefreshes[webViewId]?.generation == generation else { return }
            self.runHostedWebViewRefreshPass(
                webView,
                in: containerView,
                reason: reason,
                phase: "delayed",
                reattachRenderingState: true
            )
        }
        pending.delayedWorkItem = delayedWorkItem
        pendingHostedWebViewRefreshes[webViewId] = pending

        DispatchQueue.main.async(execute: asyncWorkItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: delayedWorkItem)
    }

    func moveWebKitRelatedSubviewsIfNeeded(
        from sourceSuperview: NSView,
        to containerView: WindowBrowserSlotView,
        primaryWebView: WKWebView,
        reason: String
    ) {
        guard sourceSuperview !== containerView else { return }
        // When Web Inspector is docked, WebKit can inject companion WK* subviews
        // next to the primary WKWebView. Move those with the web view so inspector
        // UI state does not get orphaned in the old host during split churn.
        let relatedSubviews = relatedWebKitTransferSubviews(
            from: sourceSuperview,
            primaryWebView: primaryWebView
        )
        guard !relatedSubviews.isEmpty else { return }
#if DEBUG
        cmuxDebugLog(
            "browser.portal.reparent.batch reason=\(reason) source=\(browserPortalDebugToken(sourceSuperview)) " +
            "container=\(browserPortalDebugToken(containerView)) count=\(relatedSubviews.count) " +
            "sourceType=\(String(describing: type(of: sourceSuperview))) targetType=\(String(describing: type(of: containerView))) " +
            "sourceFlipped=\(sourceSuperview.isFlipped ? 1 : 0) targetFlipped=\(containerView.isFlipped ? 1 : 0) " +
            "sourceBounds=\(browserPortalDebugFrame(sourceSuperview.bounds)) targetBounds=\(browserPortalDebugFrame(containerView.bounds))"
        )
#endif
        for view in relatedSubviews {
            let frameInWindow = sourceSuperview.convert(view.frame, to: nil)
            let className = String(describing: type(of: view))
            view.removeFromSuperview()
            containerView.addSubview(view, positioned: .above, relativeTo: nil)
            let convertedFrame = containerView.convert(frameInWindow, from: nil)
            view.frame = convertedFrame
#if DEBUG
            cmuxDebugLog(
                "browser.portal.reparent.batch.item reason=\(reason) class=\(className) " +
                "view=\(browserPortalDebugToken(view)) frameInWindow=\(browserPortalDebugFrame(frameInWindow)) " +
                "converted=\(browserPortalDebugFrame(convertedFrame))"
            )
#endif
        }
    }

}
