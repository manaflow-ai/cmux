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
/// with content hidden beyond it. It is an alpha mask on the scroll view's
/// layer, not a painted band, so it matches every theme (light, dark,
/// room, workspace) and translucent windows with no color of its own. It
/// updates from the clip view's bounds and frame notifications and the
/// document's frame notifications (no polling); an edge appears or goes
/// with the Motion `hover` fade.
@MainActor
public final class ScrollEdgeFade {
    public private(set) var edges: ScrollEdges = []
    private weak var scrollView: NSScrollView?
    private let mask = CAGradientLayer()
    private var observers: [any NSObjectProtocol] = []
    private weak var observedDocument: NSView?

    public init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        scrollView.wantsLayer = true
        mask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        mask.startPoint = CGPoint(x: 0.5, y: 1)
        mask.endPoint = CGPoint(x: 0.5, y: 0)
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        update(animated: false)
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Re-reads the scroll position; call after the document changes size
    /// when its frame notifications are off.
    public func update(animated: Bool = true) {
        guard let scrollView, let layer = scrollView.layer else { return }
        observeDocument(scrollView.documentView)
        let clip = scrollView.contentView
        let document = scrollView.documentView
        let next = document.map {
            ScrollEdges.hidden(visible: clip.documentVisibleRect, document: $0.bounds, isFlipped: $0.isFlipped)
        } ?? []
        let height = max(layer.bounds.height, 1)
        Motion.transaction(nil) {
            if layer.mask !== mask { layer.mask = mask }
            mask.frame = layer.bounds
        }
        let fade = min(Metrics.scrollEdgeFade / height, 0.4)
        let locations = [0, next.contains(.top) ? fade : 0, next.contains(.bottom) ? 1 - fade : 1, 1].map { NSNumber(value: Double($0)) }
        guard next != edges || mask.locations != locations else { return }
        edges = next
        Motion.transaction(animated ? .hover : nil) { mask.locations = locations }
    }

    private func observeDocument(_ document: NSView?) {
        guard let document, document !== observedDocument else { return }
        observedDocument = document
        document.postsFrameChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        })
    }
}
