import AppKit
import SwiftUI

/// Mounts the current Chromium host view into SwiftUI pane content.
struct ChromiumBrowserHostRepresentable: NSViewRepresentable {
    let panel: BrowserPanel

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        mountCurrentHost(in: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        mountCurrentHost(in: nsView)
        nsView.needsLayout = true
    }

    private func mountCurrentHost(in container: NSView) {
        guard let host = panel.chromiumContentView as? ChromiumBrowserHostView else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        guard host.superview !== container else {
            host.frame = container.bounds
            return
        }
        container.subviews.forEach { $0.removeFromSuperview() }
        host.removeFromSuperview()
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
    }
}
