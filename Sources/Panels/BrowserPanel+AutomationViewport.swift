import AppKit
import CmuxBrowser

extension BrowserPanel {
    @discardableResult
    func setAutomationViewport(
        _ viewport: BrowserViewport?
    ) -> Result<BrowserViewportLayout, BrowserAutomationViewportError> {
        let webView = webView
        guard !webView.cmuxIsElementFullscreenActiveOrTransitioning else {
            return .failure(.elementFullscreen)
        }
        if let host = webView.superview,
           host.browserPortalHasVisibleWebKitCompanionSubview(for: webView) {
            return .failure(.attachedBrowserInspector)
        }
        if viewportHostView.browserPortalHasVisibleWebKitCompanionSubview(for: webView) {
            return .failure(.attachedBrowserInspector)
        }

        let containerBounds = webView.cmuxBrowserViewportContainerBounds
            ?? fallbackAutomationViewportContainerBounds
        guard let layout = BrowserViewportLayout(
            containerBounds: containerBounds,
            viewport: viewport,
            pageZoom: Double(webView.pageZoom)
        ) else {
            let pageZoom = Double(webView.pageZoom)
            let maximumPageZoom = viewport.map {
                BrowserViewportRenderLimits.standard.maximumPageZoom(for: $0)
            } ?? pageZoom
            return .failure(.renderGeometryTooLarge(
                requestedPageZoom: pageZoom,
                maximumPageZoom: maximumPageZoom
            ))
        }

        viewportModel.setViewport(viewport)
        if let webView = webView as? CmuxWebView {
            webView.browserViewportModel = viewportModel
        }
        if viewport != nil {
            _ = webView.cmuxRestoreIntoBrowserViewportHostAfterExternalGeometryIfSafe()
        } else {
            _ = viewportHostView.deactivateWebView(using: layout)
        }
        webView.cmuxApplyBrowserViewportLayout(layout)
        webView.needsLayout = true
        webView.cmuxBrowserViewportPresentationView.needsLayout = true
        webView.cmuxBrowserViewportAttachmentSuperview?.needsLayout = true
        webView.cmuxBrowserViewportAttachmentSuperview?.layoutSubtreeIfNeeded()
        webView.layoutSubtreeIfNeeded()
        BrowserWindowPortalRegistry.refresh(webView: webView, reason: "automationViewport")
        return .success(layout)
    }

    func reapplyAutomationViewportAfterPageZoom() {
        guard !webView.cmuxIsElementFullscreenActiveOrTransitioning,
              let viewport = viewportModel.viewport,
              let containerBounds = webView.cmuxBrowserViewportContainerBounds else {
            return
        }
        guard BrowserViewportRenderLimits.standard.supports(
            viewport: viewport,
            pageZoom: Double(webView.pageZoom)
        ) else {
            return
        }
        if let rawHost = webView.superview,
           rawHost.browserPortalHasVisibleWebKitCompanionSubview(for: webView) {
            if let layout = webView.cmuxBrowserViewportLayout(in: containerBounds) {
                webView.cmuxBrowserViewportHostView?.apply(layout, updateWebView: false)
                webView.bounds = layout.webViewBounds
            }
        } else {
            webView.cmuxApplyBrowserViewportLayout(in: containerBounds)
        }
    }

    @discardableResult
    func reconcileAutomationViewportForElementFullscreen(isActive: Bool) -> Bool {
        if isActive {
            return viewportModel.suspendForExternalGeometry()
        }
        return viewportModel.resumeAfterExternalGeometry() != nil
    }

    func scheduleBrowserViewportHostRestoration(
        reason: String
    ) {
        guard viewportModel.requestedViewport != nil else {
            browserViewportHostRestorationTask?.cancel()
            browserViewportHostRestorationTask = nil
            browserViewportHostRestorationPending = false
            return
        }
        browserViewportHostRestorationPending = true
        browserViewportHostRestorationTask?.cancel()
        let expectedWebView = webView
        browserViewportHostRestorationTask = Task { @MainActor [weak self, weak expectedWebView] in
            await Task.yield()
            guard !Task.isCancelled,
                  let self,
                  let expectedWebView,
                  self.webView === expectedWebView,
                  self.browserViewportHostRestorationPending,
                  self.viewportModel.requestedViewport != nil else {
                return
            }
            self.browserViewportHostRestorationTask = nil
            guard !expectedWebView.cmuxIsElementFullscreenActiveOrTransitioning else {
                return
            }

            _ = expectedWebView.cmuxRestoreIntoBrowserViewportHostAfterExternalGeometryIfSafe()
            guard expectedWebView.cmuxBrowserViewportUsesHost else { return }

            self.browserViewportHostRestorationPending = false
            self.reapplyAutomationViewportAfterPageZoom()
            BrowserWindowPortalRegistry.refresh(
                webView: expectedWebView,
                reason: "viewportHostRestore.\(reason)"
            )
        }
    }

    @discardableResult
    func resetAutomationViewportForAttachedBrowserInspector() -> Bool {
        let containerBounds = webView.cmuxBrowserViewportContainerBounds ?? webView.frame
        guard let nativeLayout = viewportModel.resetForAttachedInspector(
            containerBounds: containerBounds,
            pageZoom: Double(webView.pageZoom)
        ) else {
            return false
        }
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        webView.cmuxBrowserViewportHostView?.apply(nativeLayout, updateWebView: false)
        BrowserWindowPortalRegistry.refresh(
            webView: webView,
            reason: "attachedInspectorResetAutomationViewport"
        )
        return true
    }

    func visualAutomationViewportSize() -> NSSize {
        if let viewport = viewportModel.viewport {
            return viewport.size
        }
        let candidates = [
            webView.bounds.size,
            webView.frame.size,
            webView.window?.contentView?.bounds.size ?? .zero,
        ]
        for candidate in candidates where candidate.width > 1 && candidate.height > 1 {
            return NSSize(
                width: min(max(candidate.width, 1), 4096),
                height: min(max(candidate.height, 1), 4096)
            )
        }
        return NSSize(width: 1280, height: 720)
    }

    private var fallbackAutomationViewportContainerBounds: CGRect {
        let candidates = [webView.frame.size, webView.bounds.size]
        let size = candidates.first(where: { $0.width > 1 && $0.height > 1 })
            ?? CGSize(width: 800, height: 600)
        return CGRect(origin: .zero, size: size)
    }
}
