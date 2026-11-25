public import AppKit
import CmuxNextCompat

/// Which edges of a scrolling list have content hidden beyond them.
public nonisolated struct ScrollEdges: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let top = ScrollEdges(rawValue: 1 << 0)
    public static let bottom = ScrollEdges(rawValue: 1 << 1)

    /// Slack that absorbs rounding: content hidden by less than half a
    /// point counts as nothing hidden.
    public static let slack: CGFloat = 0.5

    /// Hidden edges for a visible rect of a document, both in the
    /// document's coordinates. Elastic overscroll past an end counts as
    /// being at that end: the offset is clamped to the scrollable range
    /// first, so a rubber band never flashes either fade (a list that fits,
    /// pulled down, does not show a bottom fade).
    public static func hidden(visible: CGRect, document: CGRect, isFlipped: Bool) -> ScrollEdges {
        let range = max(0, document.height - visible.height)
        let offset = isFlipped ? visible.minY - document.minY : document.maxY - visible.maxY
        let aboveTop = min(max(offset, 0), range)
        let belowBottom = range - aboveTop
        var edges: ScrollEdges = []
        if aboveTop > slack { edges.insert(.top) }
        if belowBottom > slack { edges.insert(.bottom) }
        return edges
    }

    /// Hidden edges for a clip view's bounds and the document's frame
    /// (both in the clip's coordinates). The content insets are not part
    /// of the visible area: at the top the offset equals the top inset.
    public static func hidden(clipBounds: CGRect, insets: NSEdgeInsets, document: CGRect, isFlipped: Bool) -> ScrollEdges {
        let topInset = isFlipped ? insets.top : insets.bottom
        let visible = CGRect(
            x: clipBounds.minX,
            y: clipBounds.minY + topInset,
            width: clipBounds.width,
            height: max(0, clipBounds.height - insets.top - insets.bottom)
        )
        return hidden(visible: visible, document: document, isFlipped: isFlipped)
    }
}

/// A subtle fade at the top and bottom of a scrolling list, only on an edge
/// with content hidden beyond it: none at the top while scrolled to the
/// top, none at the bottom while scrolled to the bottom, none when the
/// content fits. The view hosts the scroll view (which fills it) and masks
/// its own layer with an alpha gradient: a mask, not a painted band, so it
/// matches every theme (light, dark, room, workspace) and translucent
/// windows with no color of its own. The mask sits on this plain view
/// because AppKit owns the scroll view's and clip view's layer masks
/// (macOS 26 scroll-edge pockets replace them). It updates from the clip
/// view's bounds and frame notifications and the document's frame
/// notifications (no polling); an edge's band fades in or out with the
/// Motion `hover` token (a short crossfade under Reduce Motion, per the
/// Motion policy).
///
/// Each band is eased, not linear: its alpha follows smoothstep from the edge
/// to full ink, sampled at ``bandSamples`` stops, so ink meets the band with
/// no slope break the eye reads as a line. The bottom band is taller than the
/// top's (`Metrics.scrollEdgeFadeBottom`), so rows roll out gradually over the
/// footer (Leo 2026-11-22: "there's simultaneously a fade AND a hard break
/// ideally lessen the hard break").
public final class ScrollEdgeFadeView: NSView {
    public let scrollView: NSScrollView
    public private(set) var edges: ScrollEdges = []
    /// Points at the top hidden outright while content is hidden above, with the top band's
    /// fade starting below them: the part of a list that sits under the window's traffic
    /// lights. At rest (nothing hidden above) the mask is opaque there, as with none. 0 by default.
    public var topClip: CGFloat = 0 {
        didSet { if oldValue != topClip { updateFade(animated: false) } }
    }
    /// Holds the top band's fade off: below `topClip` the list shows whole, though content is hidden above. For a view
    /// that stands at the list's top and must not fade (a stuck section header, which draws its own fade under it).
    /// The band's stops move on the same short crossfade as its colors. Off by default.
    public var holdsTopEdge = false {
        didSet { if oldValue != holdsTopEdge { updateFade(animated: true, movesStops: true) } }
    }
    /// Whether hidden content fades at the edges. Off, the mask stays opaque at every edge, so the
    /// whole list shows (`sidebar.noFade`). Setting it re-reads the edges at once.
    public var fades = true {
        didSet { if oldValue != fades { updateFade(animated: true) } }
    }
    private let fadeMask = CAGradientLayer()
    private var observers: [MainActorObservation] = []
    private weak var observedDocument: NSView?
    /// The layer size and band fractions the mask geometry was last set for; a scroll that finds
    /// either changed (a tunable edit, a resize with no layout yet) sets the geometry again.
    private var maskedSize: CGSize = .zero
    private var maskedFractions = Fractions(top: -1, bottom: -1)

    /// Each band's share of the list height.
    struct Fractions: Equatable {
        var top: CGFloat
        var bottom: CGFloat
    }

    /// Stops per band past its edge stop: smoothstep sampled this finely reads as one curve
    /// (no visible facets at 44 pt on a 2x display).
    public static let bandSamples = 8

    public init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init(frame: scrollView.frame)
        wantsLayer = true
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
        fadeMask.colors = Self.colors(for: [])
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        // A scroll (the clip's bounds) changes only which edges hide content; the mask's geometry
        // follows this view's own size, so a scroll frame touches the mask only when an edge flips.
        observers.append(MainActorObservation(NSView.boundsDidChangeNotification, object: clip, center: center) { [weak self] in
            self?.updateEdges()
        })
        observers.append(MainActorObservation(NSView.frameDidChangeNotification, object: clip, center: center) { [weak self] in
            self?.updateFade()
        })
        updateFade(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func layout() {
        super.layout()
        updateFade(animated: false)
    }

    /// AppKit sets the layer's geometry flip for its place in the tree, so
    /// the gradient re-orients when the view moves.
    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateFade(animated: false)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateFade(animated: false)
    }

    /// True when `layer`'s own coordinate space (where its mask lives) runs
    /// top-down on screen. Each `isGeometryFlipped` flips its layer's space
    /// relative to its superlayer's, so the flags of the layer and every
    /// ancestor combine; the root's space is bottom-up (Core Animation on
    /// macOS). A layer-backed view's own flag alone is not enough: AppKit
    /// sets it on a plain view inside a flipped one to undo the parent's
    /// flip.
    public static func rendersTopDown(_ layer: CALayer) -> Bool {
        var flipped = false
        var current: CALayer? = layer
        while let node = current {
            if node.isGeometryFlipped { flipped.toggle() }
            current = node.superlayer
        }
        return flipped
    }

    /// The edges with content hidden beyond them, from the clip's bounds,
    /// its content insets and the document's frame.
    public static func hiddenEdges(of scrollView: NSScrollView) -> ScrollEdges {
        guard let document = scrollView.documentView else { return [] }
        let clip = scrollView.contentView
        return ScrollEdges.hidden(clipBounds: clip.bounds, insets: clip.contentInsets, document: document.frame, isFlipped: clip.isFlipped)
    }

    /// Smoothstep: 0 at 0, 1 at 1, flat at both ends, so the band meets full ink and the edge
    /// with no slope break.
    public static func ease(_ t: CGFloat) -> CGFloat {
        let t = min(max(t, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Mask alphas top to bottom, one per stop of ``locations(height:fractions:topClip:holdsTop:)``:
    /// at an edge with hidden content the band eases from transparent to opaque; elsewhere opaque.
    static func alphas(for edges: ScrollEdges) -> [CGFloat] {
        let n = bandSamples
        let top = (0...n).map { edges.contains(.top) ? ease(CGFloat($0) / CGFloat(n)) : 1 }
        let bottom = (0...n).map { edges.contains(.bottom) ? ease(CGFloat(n - $0) / CGFloat(n)) : 1 }
        return top + bottom
    }

    /// Mask colors top to bottom (``alphas(for:)`` as black at that alpha).
    static func colors(for edges: ScrollEdges) -> [CGColor] {
        alphas(for: edges).map { NSColor.black.withAlphaComponent($0).cgColor }
    }

    /// Re-reads the scroll position.
    public func updateFade(animated: Bool = true) { updateFade(animated: animated, movesStops: false) }

    /// `updateFade`; `movesStops` moves the gradient's stops on the band's crossfade too (`holdsTopEdge`).
    private func updateFade(animated: Bool, movesStops: Bool) {
        guard let layer else { return }
        observeDocument(scrollView.documentView)
        let next = fades ? Self.hiddenEdges(of: scrollView) : []
        let fade = Self.fadeFractions(height: layer.bounds.height)
        maskedSize = layer.bounds.size
        maskedFractions = fade
        Motion.feedback.transaction(nil) {
            if layer.mask !== fadeMask { layer.mask = fadeMask }
            fadeMask.frame = layer.bounds
            // Gradient location 0 is the list's top on screen.
            let top: CGFloat = Self.rendersTopDown(layer) ? 0 : 1
            fadeMask.startPoint = CGPoint(x: 0.5, y: top)
            fadeMask.endPoint = CGPoint(x: 0.5, y: 1 - top)
        }
        let stops = Self.locations(height: layer.bounds.height, fractions: fade, topClip: topClip, holdsTop: holdsTopEdge)
        Motion.feedback.transaction(movesStops && animated ? .hover : nil) {
            fadeMask.locations = stops.map { NSNumber(value: Double($0)) }
        }
        setEdges(next, animated: animated)
    }

    /// Re-reads only which edges hide content (a scroll). Before the first full update (no
    /// mask yet) it does the full one.
    func updateEdges() {
        guard let layer, layer.mask === fadeMask, layer.bounds.size == maskedSize,
              Self.fadeFractions(height: layer.bounds.height) == maskedFractions else { return updateFade() }
        observeDocument(scrollView.documentView)
        setEdges(fades ? Self.hiddenEdges(of: scrollView) : [], animated: true)
    }

    /// Each band's share of the list height (its fade length, capped by the tunable).
    static func fadeFractions(height: CGFloat) -> Fractions {
        let cap = CGFloat(ChromeTunables.scrollFadeMaxFraction.value), h = max(height, 1)
        return Fractions(top: min(Metrics.scrollEdgeFade / h, cap), bottom: min(Metrics.scrollEdgeFadeBottom / h, cap))
    }

    /// Gradient stops top to bottom, as fractions of `height`, ``bandSamples`` + 1 per band: the
    /// top band holds its color down to `topClip` (the gradient's first color extends above its
    /// first stop), then eases over `fractions.top`; the bottom band eases over `fractions.bottom`
    /// to the list's bottom. The clip gives way to keep the stops in order.
    static func locations(height: CGFloat, fractions: Fractions, topClip: CGFloat, holdsTop: Bool = false) -> [CGFloat] {
        let clip = min(max(0, topClip) / max(height, 1), max(0, 1 - fractions.top - fractions.bottom))
        let n = CGFloat(bandSamples), topSpan = holdsTop ? 0 : fractions.top
        let top = (0...bandSamples).map { clip + topSpan * CGFloat($0) / n }
        let bottom = (0...bandSamples).map { 1 - fractions.bottom + fractions.bottom * CGFloat($0) / n }
        return top + bottom
    }

    private func setEdges(_ next: ScrollEdges, animated: Bool) {
        guard next != edges else { return }
        edges = next
        // The band's opacity fades; geometry above never animates.
        Motion.feedback.transaction(animated ? .hover : nil) { fadeMask.colors = Self.colors(for: next) }
    }

    private func observeDocument(_ document: NSView?) {
        guard let document, document !== observedDocument else { return }
        observedDocument = document
        document.postsFrameChangedNotifications = true
        observers.append(MainActorObservation(NSView.frameDidChangeNotification, object: document) { [weak self] in
            self?.updateFade()
        })
    }
}
