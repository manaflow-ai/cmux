import AppKit
import CmuxBrowser

extension BrowserPanel {
    @discardableResult
    func setAutomationViewport(
        _ viewport: BrowserViewport?
    ) -> Result<BrowserViewportLayout, BrowserAutomationViewportError> {
        let webView = webView
        if let host = webView.superview,
           host.browserPortalHasVisibleWebKitCompanionSubview(for: webView) {
            return .failure(.attachedBrowserInspector)
        }

        let containerBounds = webView.superview?.bounds ?? fallbackAutomationViewportContainerBounds
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
        webView.cmuxApplyBrowserViewportLayout(layout)
        webView.needsLayout = true
        webView.superview?.needsLayout = true
        webView.superview?.layoutSubtreeIfNeeded()
        webView.layoutSubtreeIfNeeded()
        BrowserWindowPortalRegistry.refresh(webView: webView, reason: "automationViewport")
        return .success(layout)
    }

    func reapplyAutomationViewportAfterPageZoom() {
        guard let viewport = viewportModel.viewport,
              let host = webView.superview else {
            return
        }
        guard BrowserViewportRenderLimits.standard.supports(
            viewport: viewport,
            pageZoom: Double(webView.pageZoom)
        ) else {
            return
        }
        if host.browserPortalHasVisibleWebKitCompanionSubview(for: webView) {
            if let layout = webView.cmuxBrowserViewportLayout(in: host.bounds) {
                webView.bounds = layout.webViewBounds
            }
        } else {
            webView.cmuxApplyBrowserViewportLayout(in: host.bounds)
        }
    }

    @discardableResult
    func resetAutomationViewportForAttachedBrowserInspector() -> Bool {
        guard viewportModel.resetForAttachedInspector() else { return false }
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
