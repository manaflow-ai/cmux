import AppKit
import SwiftUI

/// Non-hit-testing AppKit color fill used where SwiftUI colors blend poorly
/// with transparent window backdrops.
struct LayerBackedBackdropColor: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context _: Context) -> NSView {
        let view = NonHitTestingLayerBackedColorView()
        view.setBackdropColor(color)
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        (nsView as? NonHitTestingLayerBackedColorView)?.setBackdropColor(color)
    }

    private final class NonHitTestingLayerBackedColorView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = true
            layer?.isOpaque = false
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            wantsLayer = true
            layer?.masksToBounds = true
            layer?.isOpaque = false
        }

        override var isOpaque: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        func setBackdropColor(_ color: NSColor) {
            wantsLayer = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.backgroundColor = color.cgColor
            layer?.isOpaque = color.alphaComponent >= 1
            CATransaction.commit()
        }
    }
}
