import AppKit
import Foundation
import WebKit

private final class DiffViewerLoadingOverlayView: NSView {
    private let skeletonWidths: [CGFloat] = [1.0, 0.72, 0.88, 0.64, 0.94, 0.76]
    private var skeletonBars: [NSView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = GhosttyBackgroundTheme.currentColor().cgColor
        autoresizingMask = [.width, .height]
        skeletonBars = skeletonWidths.map { _ in
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
            bar.layer?.cornerRadius = 6
            addSubview(bar)
            return bar
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let horizontalInset: CGFloat = 20
        let topInset: CGFloat = 38
        let height: CGFloat = 14
        let gap: CGFloat = 20
        let availableWidth = max(0, bounds.width - horizontalInset * 2)
        for (index, bar) in skeletonBars.enumerated() {
            bar.frame = NSRect(
                x: horizontalInset,
                y: bounds.height - topInset - height - CGFloat(index) * (height + gap),
                width: availableWidth * skeletonWidths[index],
                height: height
            )
        }
    }
}

/// Hover-prewarm adoption support for ``BrowserPanel``: profile resolution
/// shared with prewarm callers, and the eligibility gate the initializer uses
/// to swap a pool-prewarmed webview in place of a cold load.
extension BrowserPanel {
    /// The profile a panel would use for the given requested ID. Shared with
    /// prewarm callers so a prewarmed webview and the panel that later adopts
    /// it resolve to the same profile and website data store.
    static func resolvedProfileID(requested: UUID?) -> UUID {
        let requestedProfileID = requested ?? BrowserProfileStore.shared.effectiveLastUsedProfileID
        return BrowserProfileStore.shared.profileDefinition(id: requestedProfileID) != nil
            ? requestedProfileID
            : BrowserProfileStore.shared.builtInDefaultProfileID
    }

    /// A prewarmed webview matching this panel's initial navigation exactly,
    /// or nil for a normal cold load. Remote workspaces, request-based
    /// navigations, and render-deferred panels never adopt.
    static func claimedPrewarmedWebView(
        isRemoteWorkspace: Bool,
        initialRequest: URLRequest?,
        renderInitialNavigation: Bool,
        initialURL: URL?,
        profileID: UUID,
        websiteDataStore: WKWebsiteDataStore
    ) -> CmuxWebView? {
        guard !isRemoteWorkspace,
              initialRequest == nil,
              renderInitialNavigation,
              let initialURL else {
            return nil
        }
        let claimed = BrowserPrewarmedWebViewPool.shared.claim(
            url: initialURL,
            profileID: profileID,
            websiteDataStore: websiteDataStore
        )
        if initialURL == DiffViewerLoadingPage.url {
            // Claiming consumes an entry. Start its successor immediately so
            // another workspace can open a responsive viewer while this one
            // prepares its diff.
            DiffViewerLoadingPage.prewarm()
        }
        return claimed
    }
}

@MainActor
enum DiffViewerLoadingPage {
    static let url: URL = {
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="color-scheme" content="light dark">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <style>
            :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
            html, body { width: 100%; height: 100%; margin: 0; background: transparent; }
            main { margin: 38px 20px; display: grid; gap: 20px; opacity: .12; }
            i { display: block; height: 14px; border-radius: 6px; background: CanvasText; }
            i:nth-child(2) { width: 72%; }
            i:nth-child(3) { width: 88%; }
            i:nth-child(4) { width: 64%; }
            i:nth-child(5) { width: 94%; }
            i:nth-child(6) { width: 76%; }
          </style>
        </head>
        <body><main aria-hidden="true"><i></i><i></i><i></i><i></i><i></i><i></i></main></body>
        </html>
        """
        let encoded = Data(html.utf8).base64EncodedString()
        return URL(string: "data:text/html;charset=utf-8;base64,\(encoded)")!
    }()

    static func prewarm() {
        BrowserPrewarmedWebViewPool.shared.prewarmTrustedInlinePage(
            url: url,
            profileID: BrowserPanel.resolvedProfileID(requested: nil)
        )
    }
}

extension BrowserPanel {
    /// Places the already-rendered loading webview over the future right split
    /// synchronously. The normal browser portal reparents the same presentation
    /// view when SwiftUI materializes the split, then this host removes itself.
    @discardableResult
    func presentDiffViewerLoadingImmediately(relativeTo sourceView: NSView) -> Bool {
        guard let window = sourceView.window,
              let contentView = window.contentView else {
            return false
        }
        let sourceFrame = sourceView.convert(sourceView.bounds, to: contentView)
        guard sourceFrame.width >= 2, sourceFrame.height >= 1 else { return false }

        closeDiffViewerImmediatePresentationHost()
        let dividerWidth: CGFloat = 1
        let targetWidth = (sourceFrame.width - dividerWidth) / 2
        let targetFrame = NSRect(
            x: sourceFrame.maxX - targetWidth,
            y: sourceFrame.minY,
            width: targetWidth,
            height: sourceFrame.height
        )
        let host = NSView(frame: targetFrame)
        host.wantsLayer = true
        host.layer?.backgroundColor = GhosttyBackgroundTheme.currentColor().cgColor
        host.identifier = NSUserInterfaceItemIdentifier("cmux.diffViewerImmediatePresentation")

        let presentationView = webView.cmuxBrowserViewportPresentationView
        presentationView.removeFromSuperview()
        presentationView.frame = host.bounds
        presentationView.autoresizingMask = [.width, .height]
        host.addSubview(presentationView)
        showDiffViewerLoadingOverlay(on: presentationView)
        contentView.addSubview(host, positioned: .above, relativeTo: nil)
        diffViewerImmediatePresentationHost = host

        webView.cmuxApplyBrowserViewportLayout(in: host.bounds)
        webView.browserPortalReattachRenderingState(reason: "diffViewerImmediatePresentation")
        host.layoutSubtreeIfNeeded()
        webView.layoutSubtreeIfNeeded()
        host.needsDisplay = true
        presentationView.needsDisplay = true
        return presentationView.window === window && !presentationView.isHidden
    }

    func closeDiffViewerImmediatePresentationHost() {
        guard let host = diffViewerImmediatePresentationHost else { return }
        diffViewerImmediatePresentationHost = nil
        host.removeFromSuperview()
    }

    private func showDiffViewerLoadingOverlay(on presentationView: NSView) {
        closeDiffViewerLoadingOverlay()
        let overlay = DiffViewerLoadingOverlayView(frame: presentationView.bounds)
        presentationView.addSubview(overlay, positioned: .above, relativeTo: nil)
        diffViewerLoadingOverlay = overlay
    }

    func closeDiffViewerLoadingOverlay() {
        diffViewerLoadingOverlay?.removeFromSuperview()
        diffViewerLoadingOverlay = nil
    }
}
