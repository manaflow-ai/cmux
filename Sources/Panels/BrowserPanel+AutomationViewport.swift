import AppKit
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

    func reapplyAutomationViewportAfterPageZoom() {
        guard viewportModel.viewport != nil,
              let host = webView.superview else {
            return
        }
        if host.browserPortalHasVisibleWebKitCompanionSubview(for: webView) {
            webView.bounds = webView.cmuxBrowserViewportLayout(in: host.bounds).webViewBounds
        } else {
            webView.cmuxApplyBrowserViewportLayout(in: host.bounds)
        }
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
