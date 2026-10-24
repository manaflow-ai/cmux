import AppKit
import QuartzCore

/// A woken tab's last picture over its layer-hosted page, until the page
/// paints (``CEFLayerHosting/showStandIn(_:owner:cap:hostingAvailable:)``).
/// It is in the cmux window's own layers, above the hosted page and below
/// nothing that takes input: it never takes the mouse.
final class CEFWakeStandInView: NSView {
    init(frame: NSRect, image: CGImage) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func isAccessibilityElement() -> Bool { false }
}
