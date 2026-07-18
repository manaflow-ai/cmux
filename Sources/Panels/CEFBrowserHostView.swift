import AppKit
import CEFKit
import SwiftUI

/// Hosts CEF content and transient omnibar UI as ordered sibling AppKit views.
@MainActor
final class CEFBrowserHostView: NSView {
    let containerView: CEFBrowserContainerView

    private var omnibarSuggestionsHostingView: BrowserPortalOmnibarSuggestionsHostingView?
    private var omnibarSuggestionsOwnerID: UUID?
    private var zOrderCheckView: NSView?

    init(containerView: CEFBrowserContainerView) {
        self.containerView = containerView
        super.init(frame: .zero)

        containerView.frame = bounds
        containerView.autoresizingMask = [.width, .height]
        addSubview(containerView)

        if ProcessInfo.processInfo.environment["CMUX_CEF_OMNIBAR_Z_ORDER_CHECK"] == "1" {
            let checkView = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 8))
            checkView.wantsLayer = true
            checkView.layer?.backgroundColor = NSColor.systemPink.withAlphaComponent(0.85).cgColor
            checkView.autoresizingMask = [.maxXMargin, .minYMargin]
            addSubview(checkView, positioned: .above, relativeTo: containerView)
            zOrderCheckView = checkView
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setOmnibarSuggestions(
        _ configuration: BrowserPortalOmnibarSuggestionsConfiguration?,
        ownerID: UUID
    ) {
        omnibarSuggestionsOwnerID = ownerID
        guard let configuration else {
            omnibarSuggestionsHostingView?.removeFromSuperview()
            omnibarSuggestionsHostingView = nil
            return
        }

        let rootView = BrowserPortalOmnibarSuggestionsOverlay(configuration: configuration)
        if let overlay = omnibarSuggestionsHostingView {
            overlay.rootView = rootView
            overlay.popupFrameInTopLeftCoordinates = configuration.popupFrame
            if overlay.superview !== self {
                installOverlay(overlay)
            }
            positionOverlayAboveContent(overlay)
            return
        }

        let overlay = BrowserPortalOmnibarSuggestionsHostingView(rootView: rootView)
        overlay.popupFrameInTopLeftCoordinates = configuration.popupFrame
        installOverlay(overlay)
        omnibarSuggestionsHostingView = overlay
    }

    func clearOmnibarSuggestions(ownerID: UUID) {
        guard omnibarSuggestionsOwnerID == ownerID else { return }
        omnibarSuggestionsOwnerID = nil
        omnibarSuggestionsHostingView?.removeFromSuperview()
        omnibarSuggestionsHostingView = nil
    }

    private func installOverlay(_ overlay: BrowserPortalOmnibarSuggestionsHostingView) {
        overlay.removeFromSuperview()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay, positioned: .above, relativeTo: zOrderCheckView ?? containerView)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private func positionOverlayAboveContent(
        _ overlay: BrowserPortalOmnibarSuggestionsHostingView
    ) {
        addSubview(overlay, positioned: .above, relativeTo: zOrderCheckView ?? containerView)
    }
}
