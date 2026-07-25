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
enum DiffViewerImmediatePresentationPlacement {
    case futureRightSplit
    case existingTargetPane

    func targetFrame(in referenceFrame: NSRect) -> NSRect {
        switch self {
        case .futureRightSplit:
            let dividerWidth: CGFloat = 1
            let targetWidth = (referenceFrame.width - dividerWidth) / 2
            return NSRect(
                x: referenceFrame.maxX - targetWidth,
                y: referenceFrame.minY,
                width: targetWidth,
                height: referenceFrame.height
            )
        case .existingTargetPane:
            return referenceFrame
        }
    }
}

@MainActor
final class DiffViewerImmediateLoadingPresentation {
    private var host: NSView?

    init?(
        relativeTo referenceView: NSView,
        placement: DiffViewerImmediatePresentationPlacement
    ) {
        guard let window = referenceView.window,
              let contentView = window.contentView else {
            return nil
        }
        let referenceFrame = referenceView.convert(referenceView.bounds, to: contentView)
        guard referenceFrame.width >= 2, referenceFrame.height >= 1 else { return nil }

        let host = NSView(frame: placement.targetFrame(in: referenceFrame))
        host.wantsLayer = true
        host.layer?.backgroundColor = GhosttyBackgroundTheme.currentColor().cgColor
        host.identifier = NSUserInterfaceItemIdentifier("cmux.diffViewerImmediateLoading")
        host.autoresizingMask = []
        host.addSubview(DiffViewerLoadingOverlayView(frame: host.bounds))
        contentView.addSubview(host, positioned: .above, relativeTo: nil)
        contentView.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        window.displayIfNeeded()
        self.host = host
    }

    func close() {
        host?.removeFromSuperview()
        host = nil
    }

}

/// Owns the best available first-frame presentation without making that
/// optimization a prerequisite for opening the diff viewer. Panel types that
/// do not expose an AppKit presentation view still proceed to browser creation,
/// where the prewarmed loading page supplies the skeleton.
@MainActor
final class DiffViewerInitialLoadingPresentation {
    typealias Target = (
        referenceView: NSView,
        placement: DiffViewerImmediatePresentationPlacement
    )

    private var immediatePresentation: DiffViewerImmediateLoadingPresentation?

    init(target: Target?) {
        guard let target else { return }
        immediatePresentation = DiffViewerImmediateLoadingPresentation(
            relativeTo: target.referenceView,
            placement: target.placement
        )
    }

    var isPresented: Bool {
        immediatePresentation != nil
    }

    func close() {
        immediatePresentation?.close()
        immediatePresentation = nil
    }
}

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

    static func owns(
        url currentURL: URL?,
        expectedURL: String,
        ownedOpeningURL: String?
    ) -> Bool {
        guard let currentURL else { return false }
        if currentURL.absoluteString == expectedURL {
            return true
        }
        return currentURL.absoluteString == ownedOpeningURL
    }

    static func ownershipURL(
        committedURL: URL?,
        provisionalURL: URL?,
        isProvisionalNavigationActive: Bool
    ) -> URL? {
        isProvisionalNavigationActive ? provisionalURL : committedURL
    }

    static func isPending(
        url currentURL: URL?,
        expectedURL: String,
        ownedOpeningURL: String?,
        openingDocumentHasPendingMarker: Bool
    ) -> Bool {
        guard let currentURL else { return false }
        if currentURL.absoluteString == expectedURL {
            return true
        }
        guard currentURL.absoluteString == ownedOpeningURL else {
            return false
        }
        return openingDocumentHasPendingMarker
    }
}

extension BrowserPanel {
    /// Places the already-rendered loading webview over the future right split
    /// synchronously. The normal browser portal reparents the same presentation
    /// view when SwiftUI materializes the split, then this host removes itself.
    @discardableResult
    func presentDiffViewerLoadingImmediately(
        relativeTo referenceView: NSView,
        placement: DiffViewerImmediatePresentationPlacement = .futureRightSplit
    ) -> Bool {
        guard let window = referenceView.window,
              let contentView = window.contentView else {
            return false
        }
        let referenceFrame = referenceView.convert(referenceView.bounds, to: contentView)
        guard referenceFrame.width >= 2, referenceFrame.height >= 1 else { return false }

        closeDiffViewerImmediatePresentationHost()
        let targetFrame = placement.targetFrame(in: referenceFrame)
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
