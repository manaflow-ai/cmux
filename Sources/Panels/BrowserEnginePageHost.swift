import AppKit
import CmuxBrowser
import SwiftUI

/// Places a non-WebKit page's content view in a browser pane.
///
/// The page's content view fills the pane. For a Chromium page it is the
/// placeholder its Chromium window tracks, so the page follows the pane's
/// frame and visibility.
struct BrowserEnginePageHost: NSViewRepresentable {
    let page: any BrowserPage
    let isVisible: Bool
    let shouldFocus: Bool

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        attach(page.contentView, to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if page.contentView.superview !== container {
            attach(page.contentView, to: container)
        }
        page.setContentVisible(isVisible)
        if shouldFocus, isVisible {
            page.setFocused(true)
        }
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        for subview in container.subviews {
            subview.removeFromSuperview()
        }
    }

    private func attach(_ content: NSView, to container: NSView) {
        content.removeFromSuperview()
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
    }
}
