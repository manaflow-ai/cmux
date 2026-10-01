public import AppKit

/// Which edges of a scrolling list have content hidden beyond them.
public nonisolated struct ScrollEdges: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let top = ScrollEdges(rawValue: 1 << 0)
    public static let bottom = ScrollEdges(rawValue: 1 << 1)

    /// Hidden edges for a visible rect of a document, both in the
    /// document's coordinates. Half a point of slack absorbs rounding, and
    /// elastic overscroll past an end counts as nothing hidden there.
    public static func hidden(visible: CGRect, document: CGRect, isFlipped: Bool) -> ScrollEdges {
        let slack: CGFloat = 0.5
        let aboveTop = isFlipped ? visible.minY - document.minY : document.maxY - visible.maxY
        let belowBottom = isFlipped ? document.maxY - visible.maxY : visible.minY - document.minY
        var edges: ScrollEdges = []
        if aboveTop > slack { edges.insert(.top) }
        if belowBottom > slack { edges.insert(.bottom) }
        return edges
    }
}

/// A subtle fade at the top and bottom of a scrolling list, only on an edge
/// with content hidden beyond it. The view hosts the scroll view (which
/// fills it) and masks its own layer with an alpha gradient: a mask, not a
/// painted band, so it matches every theme (light, dark, room, workspace)
/// and translucent windows with no color of its own. The mask sits on this
/// plain view because AppKit owns the scroll view's and clip view's layer
/// masks (macOS 26 scroll-edge pockets replace them). It updates from the
/// clip view's bounds and frame notifications and the document's frame
/// notifications (no polling); an edge appears or goes with the Motion
/// `hover` fade.
public final class ScrollEdgeFadeView: NSView {
    public let scrollView: NSScrollView
    public private(set) var edges: ScrollEdges = []
    private let fadeMask = CAGradientLayer()
    private var observers: [any NSObjectProtocol] = []
    private weak var observedDocument: NSView?

    public init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init(frame: scrollView.frame)
        wantsLayer = true
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
        fadeMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateFade() }
            })
        }
        updateFade(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    public override func layout() {
        super.layout()
        updateFade(animated: false)
    }

    /// Re-reads the scroll position.
    public func updateFade(animated: Bool = true) {
        guard let layer else { return }
        observeDocument(scrollView.documentView)
        let next = scrollView.documentView.map {
            ScrollEdges.hidden(visible: scrollView.contentView.documentVisibleRect, document: $0.bounds, isFlipped: $0.isFlipped)
        } ?? []
        Motion.transaction(nil) {
            if layer.mask !== fadeMask { layer.mask = fadeMask }
            fadeMask.frame = layer.bounds
            // Gradient location 0 is the list's top.
            let top: CGFloat = layer.isGeometryFlipped ? 0 : 1
            fadeMask.startPoint = CGPoint(x: 0.5, y: top)
            fadeMask.endPoint = CGPoint(x: 0.5, y: 1 - top)
        }
        let fade = min(Metrics.scrollEdgeFade / max(layer.bounds.height, 1), 0.4)
        let locations = [0, next.contains(.top) ? fade : 0, next.contains(.bottom) ? 1 - fade : 1, 1].map { NSNumber(value: Double($0)) }
        guard next != edges || fadeMask.locations != locations else { return }
        edges = next
        Motion.transaction(animated ? .hover : nil) { fadeMask.locations = locations }
    }

    private func observeDocument(_ document: NSView?) {
        guard let document, document !== observedDocument else { return }
        observedDocument = document
        document.postsFrameChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFade() }
        })
    }
}
