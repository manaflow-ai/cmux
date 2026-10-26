import AppKit
import QuartzCore

extension ChromiumHostPageView {
    static let noActions: [String: any CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "sublayers": NSNull(), "contents": NSNull(), "hidden": NSNull(),
        "backgroundColor": NSNull(),
    ]

    /// The page's pixels: a layer-hosting view (its layer is set before
    /// `wantsLayer`, so AppKit sizes the root with the view and never touches
    /// the remote layer under it). It has no subviews, as Apple asks of a
    /// layer-hosting view, and never takes the mouse.
    final class Surface: NSView {
        /// The shown context, 0 while none.
        private(set) var contextID: UInt32 = 0
        /// The root layer's background (``ChromiumHostPageView/backgroundFill``).
        var fill: CGColor? {
            didSet {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                root.backgroundColor = fill
                CATransaction.commit()
            }
        }
        private let root = CALayer()
        private var remote: CALayer?
        private let makeLayerHost: (UInt32) -> CALayer?

        init(frame: NSRect, makeLayerHost: @escaping (UInt32) -> CALayer?) {
            self.makeLayerHost = makeLayerHost
            super.init(frame: frame)
            root.masksToBounds = true
            root.actions = ChromiumHostPageView.noActions
            layer = root
            wantsLayer = true
            autoresizingMask = [.width, .height]
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        /// Unflipped: the page's root layer has its origin at the bottom left.
        override var isFlipped: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }

        /// ``ChromiumHostPageView/show(contextID:)``.
        func show(contextID id: UInt32) -> Bool {
            guard id != contextID else { return true }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            remote?.removeFromSuperlayer()
            remote = nil
            contextID = 0
            if id != 0, let layerHost = makeLayerHost(id) {
                layerHost.anchorPoint = .zero
                layerHost.position = .zero
                layerHost.actions = ChromiumHostPageView.noActions
                root.addSublayer(layerHost)
                remote = layerHost
                contextID = id
            }
            CATransaction.commit()
            return contextID == id
        }
    }
}
