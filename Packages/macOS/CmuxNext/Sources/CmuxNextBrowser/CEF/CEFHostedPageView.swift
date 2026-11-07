import AppKit
import CmuxNextRemoteLayer
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
/// Where a page window shows none of its page's pixels in the web contents: before a tab's first real page (the New Tab
/// page, a blank page) the web contents are a hole, so the window backdrop shows there (`CEFTab.applyOcclusion`).
enum CEFPageHole: Equatable {
    /// The page shows all its pixels.
    case none
    /// The whole page is a hole.
    case whole
    /// Only this rect (the web contents beside an open side panel), in the host view's coordinates, is a hole.
    case rect(CGRect)
}

final class CEFHostedPageView: NSView {
    /// The hosted context, 0 while no page is hosted.
    private(set) var contextID: UInt32 = 0
    private let root = CALayer()
    private var remote: CALayer?
    private let makeLayerHost: (UInt32) -> CALayer?

    /// - Parameter makeLayerHost: the layer that shows a context id; a
    ///   `CALayerHost` by default (tests pass one that fails).
    init(frame: NSRect, makeLayerHost: @escaping (UInt32) -> CALayer? = { CEFHostedPageView.layerHost(contextID: $0) }) {
        self.makeLayerHost = makeLayerHost
        super.init(frame: frame)
        // Layer-hosting view (layer set before wantsLayer): AppKit sizes
        // the root with the view and never touches the remote layer under it.
        root.masksToBounds = true
        root.actions = Self.noActions
        layer = root
        wantsLayer = true
        // m18: a page's pixels never pass its pane's edge, also while its last frame is larger than the shrunk pane.
        // AppKit keeps the layer's masksToBounds in step with clipsToBounds (macOS 14), so the view must clip too.
        clipsToBounds = true
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Where the page window shows none of the page's pixels (`CEFLayerHosting.pageHole`): this view shows none there
    /// either, through a mask on its root layer, so the window backdrop shows as over the page window's hole.
    var hole: CEFPageHole = .none {
        didSet { if hole != oldValue { applyHole() } }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // A partial hole's mask covers the bounds; the other cases do not depend on the size.
        if case .rect = hole { applyHole() }
    }

    private func applyHole() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch hole {
        case .none:
            root.mask = nil
        case .whole:
            // An empty mask covers no point: the page shows nothing, at any size.
            let mask = CALayer()
            mask.actions = Self.noActions
            root.mask = mask
        case .rect(let rect):
            let mask = root.mask as? CAShapeLayer ?? CAShapeLayer()
            mask.actions = Self.noActions
            mask.frame = root.bounds
            let path = CGMutablePath()
            path.addRect(root.bounds)
            path.addRect(rect)
            mask.path = path
            mask.fillRule = .evenOdd
            root.mask = mask
        }
        CATransaction.commit()
    }

    /// Not flipped: the fork's root layer is unflipped, origin bottom left.
    override var isFlipped: Bool { false }

    /// Input goes to the page window above; this view never takes the mouse.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func isAccessibilityElement() -> Bool { false }

    /// `debug.cef` `tracker.hosted_pages` counts the hosted views in a
    /// window, so a view released with its host (DevTools closed, a pane
    /// closed) never stays counted.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if window == nil, newWindow != nil {
            CEFHostView.trackerStats.hostedPages += 1
        } else if window != nil, newWindow == nil {
            CEFHostView.trackerStats.hostedPages -= 1
        }
    }

    /// Shows the context `id` (0 removes the page). False when `id` is not 0
    /// and nothing can show it (no `CALayerHost`): the caller gives the page
    /// its own window back instead of leaving it blank.
    @discardableResult
    func host(contextID id: UInt32) -> Bool {
        guard id != contextID else { return true }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        remote?.removeFromSuperlayer()
        remote = nil
        contextID = 0
        if id != 0, let layerHost = makeLayerHost(id) {
            layerHost.anchorPoint = .zero
            layerHost.position = .zero
            layerHost.actions = Self.noActions
            root.addSublayer(layerHost)
            remote = layerHost
            contextID = id
        }
        CATransaction.commit()
        return contextID == id
    }

    /// `CALayerHost` is QuartzCore SPI, the class Chromium itself uses to
    /// show its GPU process's output (`ui::DisplayCALayerTree`).
    nonisolated static func layerHost(contextID: UInt32) -> CALayer? {
        let layerHost = CALayerHost()
        layerHost.contextId = contextID
        return layerHost
    }

    private static let noActions: [String: any CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "sublayers": NSNull(), "contents": NSNull(), "hidden": NSNull(),
        "path": NSNull(),
    ]
}
