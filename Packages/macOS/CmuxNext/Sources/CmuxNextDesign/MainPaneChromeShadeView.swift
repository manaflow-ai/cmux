public import AppKit
import CmuxNextCompat

/// The shade over the chrome around the curved main pane: the window minus
/// the pane's rounded rect, filled with black at a low alpha. It sits on
/// the window's one backdrop, under the sidebar and the titlebar (both
/// clear), so they and the gutter read as chrome and the pane as a card,
/// over an opaque or a translucent window alike. Takes no clicks.
/// Floating panes (`Metrics.floatingPanes`): the shade leaves out each
/// pane's card (`paneCards`) instead of the main pane, so the sidebar, the
/// titlebar and every gap share the one darker color and the panes keep
/// the window's own surface (Ghostty background, art and opacity).
public final class MainPaneChromeShadeView: NSView {
    private let shade = CAShapeLayer()
    private var card: CGRect = .zero
    private var radius: CGFloat = 0
    private var alpha: CGFloat = 0
    /// The flush corner paints the top wedges above the content, so the shade below leaves both corners clear.
    private var squareTopCorners = false
    /// The selected folder tabs of the top row (``update(card:radius:alpha:squareTopCorners:folders:)``).
    private var folders: [CGPath] = []
    /// The tab row's divider (``update(card:radius:alpha:squareTopCorners:folders:dividers:)``): its segments, each a
    /// line of no height.
    private var dividers: [CGRect] = []
    /// The divider's line, in `Palette.chromeDivider` at ``Metrics/tabRowDividerStrength``, less the folders.
    private let dividerLayer = CAShapeLayer()
    private var cardsObservation: AnyObject?
    /// Repaints the divider on a live change to `chrome.dividerStrength` (Debug Settings), as the update and the
    /// appearance do.
    private var dividerStrengthWatch: Task<Void, Never>?
    /// The shown workspace's pane cards; a sync of theirs reshapes the shade.
    public weak var paneCards: (any PaneCardSource)? {
        didSet {
            if paneCards !== oldValue {
                cardsObservation = paneCards?.observePaneCards { [weak self] in
                    if Metrics.floatingPanes { self?.rebuild() }
                }
            }
            rebuild()
        }
    }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        shade.fillRule = .evenOdd
        layer?.addSublayer(shade)
        dividerLayer.fillRule = .evenOdd
        layer?.addSublayer(dividerLayer)
        dividerStrengthWatch = Task { [weak self] in
            for await _ in ObservationStream({ ChromeTunables.dividerStrength.value }) { self?.rebuild() }
        }
    }

    // The watch is Sendable and cancels from any thread (`GlassModeWatch`'s deinit).
    nonisolated deinit {
        dividerStrengthWatch?.cancel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The window resized (its autoresizing frame may land after the card's
    /// in the same pass): the path follows these bounds.
    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rebuild()
    }

    /// Shades everything but `card` (this view's coordinates); no shade when
    /// `alpha` is 0.
    /// `squareTopCorners`: the top corners are shaded by `CornerFlushChrome`, not this layer.
    /// `folders`: the selected folder tabs of the top row, in this view's coordinates (`CornerFlushChrome`).
    /// The shade leaves them out as it leaves out the card, so each folder tab shows the window's backdrop
    /// exactly as the content it opens does (``Palette/folderTabFill``).
    /// `dividers`: the tab row's bottom edge as lines of no height (`CornerFlushChrome.dividerLine`, less the panes
    /// whose toolbar meets their tabs), or none. It draws a hairline there in `Palette.separator` at
    /// ``Metrics/tabRowDividerStrength`` (nothing at the full title area contrast), less the folder tabs, so the line
    /// runs under the unselected tabs only.
    public func update(card: CGRect, radius: CGFloat, alpha: CGFloat, squareTopCorners: Bool = false, folders: [CGPath] = [],
                       dividers: [CGRect] = []) {
        guard card != self.card || radius != self.radius || alpha != self.alpha || squareTopCorners != self.squareTopCorners
            || folders != self.folders || dividers != self.dividers || shade.frame != bounds || Metrics.floatingPanes else { return }
        self.card = card
        self.radius = radius
        self.alpha = alpha
        self.squareTopCorners = squareTopCorners
        self.folders = folders
        self.dividers = dividers
        rebuild()
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }

    /// The divider's line: `Metrics.dividerThickness` above each of `dividers` (maxY is the top, so it sits in the tab row),
    /// less the folder tabs; nil when there is no divider or the title area contrast leaves it no strength.
    private func rebuildDivider() {
        dividerLayer.frame = bounds
        let strength = Metrics.tabRowDividerStrength
        let segments = dividers.filter { !$0.isNull && $0.width > 0 }
        guard !segments.isEmpty, strength > 0 else {
            dividerLayer.path = nil
            return
        }
        // The split panes' and the sidebar's line weight (`Metrics.dividerThickness`), so the three dividers match.
        let weight = Metrics.lineWidth(Metrics.dividerThickness)
        let rects = CGMutablePath()
        for segment in segments { rects.addRect(CGRect(x: segment.minX, y: segment.minY, width: segment.width, height: weight)) }
        var line: CGPath = rects
        for folder in folders { line = line.subtracting(folder) }
        dividerLayer.path = line
        // In the window's theme scope, as the split lines and the tab separators read it: a workspace-specific theme's
        // divider, not the app theme's (#41989 F1).
        let ink = performWithTheme { Palette.chromeDivider }
        dividerLayer.fillColor = ink.withAlphaComponent(ink.alphaComponent * strength).cgColor
    }

    private func rebuild() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        shade.frame = bounds
        rebuildDivider()
        guard alpha > 0, !card.isEmpty else {
            shade.path = nil
            return
        }
        // Floating panes leave out each pane's card (content with no panes,
        // a top page, keeps the main pane's card), as one union so holes
        // that overlap mid-motion stay unshaded.
        if Metrics.floatingPanes, let paneCards {
            let cut = paneCards.paneCardsInWindow.reduce(CGMutablePath()) { union, card in
                let rect = convert(card.rect, from: nil), corner = min(card.radius, rect.width / 2, rect.height / 2)
                let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
                return (union.isEmpty ? path : union.union(path)).mutableCopy() ?? union
            }
            // The card clips its panes: a pane wider than the card cuts no shade past its edge.
            let corner = min(radius, card.width / 2, card.height / 2)
            let visible = cut.intersection(CGPath(roundedRect: card, cornerWidth: corner, cornerHeight: corner, transform: nil))
            shade.path = CGPath(rect: bounds, transform: nil).subtracting(visible)
        } else if squareTopCorners || !folders.isEmpty {
            let corner = min(radius, card.width / 2, card.height / 2)
            var hole = CGPath(roundedRect: card, cornerWidth: corner, cornerHeight: corner, transform: nil)
            if squareTopCorners {
                hole = hole.union(CGPath(rect: CGRect(x: card.minX, y: card.maxY - corner, width: corner, height: corner), transform: nil))
                    .union(CGPath(rect: CGRect(x: card.maxX - corner, y: card.maxY - corner, width: corner, height: corner), transform: nil))
            }
            // One union per selected folder: a strip per top-row pane, so a handful at most.
            for folder in folders { hole = hole.union(folder) }
            shade.path = CGPath(rect: bounds, transform: nil).subtracting(hole)
        } else {
            let path = CGMutablePath()
            path.addRect(bounds)
            let corner = min(radius, card.width / 2, card.height / 2)
            path.addRoundedRect(in: card, cornerWidth: corner, cornerHeight: corner)
            shade.path = path
        }
        shade.fillColor = NSColor.black.withAlphaComponent(alpha).cgColor
    }
}

/// One pane's card on the window: its rect in window coordinates and its
/// corner radius (`MainPaneChromeShadeView.paneCards`).
public nonisolated struct PaneCard: Equatable, Sendable {
    public var rect: CGRect
    public var radius: CGFloat

    public init(rect: CGRect, radius: CGFloat) {
        self.rect = rect
        self.radius = radius
    }
}

/// What shows the panes of a window's workspace (the layout root): their
/// cards as displayed now, and a callback whenever they move.
@MainActor
public protocol PaneCardSource: AnyObject {
    var paneCardsInWindow: [PaneCard] { get }
    /// Calls `block` after the panes moved; lives as long as the result.
    func observePaneCards(_ block: @escaping () -> Void) -> AnyObject
}
