import AppKit
import Foundation
import WebKit

private final class DiffViewerLoadingOverlayView: NSView {
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: String(
        localized: "diffViewer.loadingDiff",
        defaultValue: "Loading diff..."
    ))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = GhosttyBackgroundTheme.currentColor().cgColor
        autoresizingMask = [.width, .height]
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        addSubview(spinner)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        label.sizeToFit()
        let spinnerSize = NSSize(width: 16, height: 16)
        let gap: CGFloat = 10
        let totalWidth = spinnerSize.width + gap + label.frame.width
        let origin = NSPoint(
            x: (bounds.width - totalWidth) / 2,
            y: (bounds.height - max(spinnerSize.height, label.frame.height)) / 2
        )
        spinner.frame = NSRect(origin: origin, size: spinnerSize)
        label.frame.origin = NSPoint(
            x: origin.x + spinnerSize.width + gap,
            y: origin.y + (spinnerSize.height - label.frame.height) / 2
        )
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
        let title = String(localized: "diffViewer.loadingDiff", defaultValue: "Loading diff...")
        let escapedTitle = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
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
            body { display: grid; place-items: center; color: color-mix(in srgb, CanvasText 72%, transparent); }
            main { display: flex; align-items: center; gap: 10px; font-size: 13px; }
            i { width: 14px; height: 14px; border: 2px solid color-mix(in srgb, CanvasText 18%, transparent);
                border-top-color: color-mix(in srgb, CanvasText 68%, transparent); border-radius: 50%;
                animation: spin .8s linear infinite; }
            @keyframes spin { to { transform: rotate(360deg); } }
            @media (prefers-reduced-motion: reduce) { i { animation: none; } }
          </style>
        </head>
        <body><main><i aria-hidden="true"></i><span>\(escapedTitle)</span></main></body>
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
