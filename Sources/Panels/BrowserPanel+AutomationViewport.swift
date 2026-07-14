import CmuxBrowser

extension BrowserPanel {
    @discardableResult
    func setAutomationViewport(_ viewport: BrowserViewport?) -> BrowserViewportLayout? {
        let webView = webView
        if let host = webView.superview,
           host.browserPortalHasVisibleWebKitCompanionSubview(for: webView) {
            return nil
        }

        viewportModel.setViewport(viewport)
        if let webView = webView as? CmuxWebView {
            webView.browserViewportModel = viewportModel
        }

        let containerBounds = webView.superview?.bounds ?? fallbackAutomationViewportContainerBounds
        let layout = webView.cmuxApplyBrowserViewportLayout(in: containerBounds)
        webView.needsLayout = true
        webView.superview?.needsLayout = true
        webView.superview?.layoutSubtreeIfNeeded()
        webView.layoutSubtreeIfNeeded()
        BrowserWindowPortalRegistry.refresh(webView: webView, reason: "automationViewport")
        return layout
    }

    private var fallbackAutomationViewportContainerBounds: CGRect {
        let candidates = [webView.frame.size, webView.bounds.size]
        let size = candidates.first(where: { $0.width > 1 && $0.height > 1 })
            ?? CGSize(width: 800, height: 600)
        return CGRect(origin: .zero, size: size)
    }
}
