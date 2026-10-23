import AppKit
import QuartzCore

/// The page's pixels inside the cmux window's own layer tree (fork API 26,
/// `cmux_browser_set_layer_hosting`). The fork moves Chromium's compositor
/// output into a Core Animation context and gives its id; this view hosts
/// that context with a `CALayerHost`, so the page moves, clips, hides and
/// shows in the same Core Animation transaction as the panes around it,
/// with no WindowServer round trip for its pixels. The page window stays
/// over `CEFHostView` as a transparent input target (mouse, keyboard, IME,
/// drag and drop, accessibility are unchanged).
///
/// A context id is a WindowServer name, not a pointer: the same view hosts
/// a page whose browser runs in another process.
final class CEFHostedPageView: NSView {
    /// The hosted context, 0 while no page is hosted.
    private(set) var contextID: UInt32 = 0
    private let root = CALayer()
    private var remote: CALayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Layer-hosting view (layer set before wantsLayer): AppKit sizes
        // the root with the view and never touches the remote layer under it.
        root.masksToBounds = true
        root.actions = Self.noActions
        layer = root
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Not flipped: the fork's root layer is unflipped, origin bottom left.
    override var isFlipped: Bool { false }

    /// Input goes to the page window above; this view never takes the mouse.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func isAccessibilityElement() -> Bool { false }

    /// Shows the context `id` (0 removes the page).
    func host(contextID id: UInt32) {
        guard id != contextID else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        remote?.removeFromSuperlayer()
        remote = nil
        contextID = 0
        if id != 0, let layerHost = Self.makeLayerHost(contextID: id) {
            layerHost.anchorPoint = .zero
            layerHost.position = .zero
            layerHost.actions = Self.noActions
            root.addSublayer(layerHost)
            remote = layerHost
            contextID = id
        }
        CATransaction.commit()
    }

    /// `CALayerHost` is QuartzCore SPI, the class Chromium itself uses to
    /// show its GPU process's output (`ui::DisplayCALayerTree`).
    private static func makeLayerHost(contextID: UInt32) -> CALayer? {
        guard let type = NSClassFromString("CALayerHost") as? CALayer.Type else { return nil }
        let layerHost = type.init()
        layerHost.setValue(NSNumber(value: contextID), forKey: "contextId")
        return layerHost
    }

    private static let noActions: [String: any CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "sublayers": NSNull(), "contents": NSNull(), "hidden": NSNull(),
    ]
}
