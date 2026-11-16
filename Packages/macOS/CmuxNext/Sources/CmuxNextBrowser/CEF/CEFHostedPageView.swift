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
    /// The hosted context's root layer when that context is in this process (``remoteRoot``), held by its top-left
    /// corner; nil when it is not (the layer host then holds the root by its bottom-left corner, as the fork places it).
    private weak var contextRoot: CALayer?
    private let makeLayerHost: (UInt32) -> CALayer?
    private let remoteRoot: (UInt32) -> CALayer?

    /// - Parameters:
    ///   - makeLayerHost: the layer that shows a context id; a `CALayerHost` by default (tests pass one that fails).
    ///   - remoteRoot: the root layer of the context a context id names, when that context is in this process; nil
    ///     when it is not (a browser in another process).
    init(frame: NSRect, makeLayerHost: @escaping (UInt32) -> CALayer? = { CEFHostedPageView.layerHost(contextID: $0) },
         remoteRoot: @escaping (UInt32) -> CALayer? = { CEFHostedPageView.inProcessRoot(contextID: $0) }) {
        self.makeLayerHost = makeLayerHost
        self.remoteRoot = remoteRoot
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
        placeRemote()
        // A partial hole's mask covers the bounds; the other cases do not depend on the size.
        if case .rect = hole { applyHole() }
    }

    /// cmux-ad m81: the page's top-left corner stays on this view's top-left corner, whatever size the fork's root has in
    /// a frame. The fork sizes its root to the page window (`adoptDisplayLayers`), and that size and this view's size do
    /// not show in the same frame (cmux21, 120 Hz: the root showed the next spring frame's height while the pane showed
    /// this one's). Held by its bottom-left corner in this unflipped view, the page moved as a whole by the difference in
    /// each such frame of a split, then back. Held by its top-left corner, a size that differs only cuts or uncovers the
    /// page's bottom edge, beside the page's backdrop, as the trailing edge already does. The layer host's position is
    /// this view's layout, so it commits with the pane.
    private func placeRemote() {
        guard let remote else { return }
        let position = CGPoint(x: 0, y: contextRoot == nil ? 0 : bounds.height)
        guard remote.position != position else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        remote.position = position
        CATransaction.commit()
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

    /// Not flipped: the fork's root layer is unflipped, origin bottom left (its top-left corner is held: ``placeRemote()``).
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
        contextRoot = nil
        contextID = 0
        if id != 0, let layerHost = makeLayerHost(id) {
            layerHost.anchorPoint = .zero
            layerHost.position = .zero
            layerHost.actions = Self.noActions
            if let contextRoot = remoteRoot(id) {
                // The root's top-left corner on the layer host (its position stays the fork's zero), and the layer
                // host on this view's top-left corner (``placeRemote()``).
                contextRoot.anchorPoint = CGPoint(x: 0, y: 1)
                self.contextRoot = contextRoot
            }
            root.addSublayer(layerHost)
            remote = layerHost
            contextID = id
            placeRemote()
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

    /// The root layer of the Core Animation context `contextID` names, when that context is in this process (the fork's
    /// `_hostRoot`); nil for a context of another process or an OS without the SPI. QuartzCore SPI, as `debug.layers` reads
    /// it: `+[CAContext allContexts]`, `-[CAContext contextId]`, `-[CAContext layer]`, each sent only after `responds(to:)`.
    nonisolated static func inProcessRoot(contextID: UInt32) -> CALayer? {
        let contextIdGetter = #selector(getter: QuartzContextSPI.contextId)
        let layerGetter = #selector(getter: QuartzContextSPI.layer)
        guard contextID != 0, let contextClass: AnyClass = NSClassFromString("CAContext"),
              (contextClass as AnyObject).responds(to: #selector(QuartzContextSPI.allContexts)),
              let contexts = (contextClass as AnyObject).perform(#selector(QuartzContextSPI.allContexts))?
                  .takeUnretainedValue() as? [NSObject] else { return nil }
        for context in contexts {
            guard context.responds(to: contextIdGetter) else { continue }
            guard context.responds(to: layerGetter) else { continue }
            let spi = unsafeBitCast(context, to: QuartzContextSPI.self)
            if spi.contextId == contextID { return spi.layer }
        }
        return nil
    }

    private static let noActions: [String: any CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "sublayers": NSNull(), "contents": NSNull(), "hidden": NSNull(),
        "path": NSNull(),
    ]
}

/// The QuartzCore SPI ``CEFHostedPageView/inProcessRoot(contextID:)`` reads. No class conforms; a caller casts an object
/// it asked `responds(to:)` for the one message it sends. `nonisolated`: the reader is a nonisolated function (the
/// initializer's default value calls it), and the module's default isolation would make these getters main-actor ones.
@objc private nonisolated protocol QuartzContextSPI {
    /// `+[CAContext allContexts]`: an instance requirement because `#selector` cannot name a static one of a protocol;
    /// it is sent to the class object with `perform(_:)`.
    func allContexts() -> [NSObject]?
    var contextId: UInt32 { get }
    var layer: CALayer? { get }
}
