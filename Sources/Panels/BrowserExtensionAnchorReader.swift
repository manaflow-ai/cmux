import AppKit
import SwiftUI

/// Attaches a ``BrowserExtensionAnchor`` to the view it backs.
struct BrowserExtensionAnchorReader: NSViewRepresentable {
    let anchor: BrowserExtensionAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
