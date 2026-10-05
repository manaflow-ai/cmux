import AppKit
import CmuxNextDesign
import QuartzCore

/// The lower part of the suggestion card: flush under the bar, as wide as
/// the card top (`OmnibarCardTopView`), rounded at the bottom only, with
/// 28 pt rows whose icon and text line up with the bar's chip and text.
/// It draws on the window's overlay host in the `.pane` layer, clipped to
/// the browser pane (plans/cmux-next/overlay-host.md), so it stays above
/// Chromium page windows without a panel of its own and never takes key
/// status from the field being edited.
///
/// Rows only report the pointer and clicks; the omnibar state machine
/// decides which one row is highlighted.
final class OmniboxSuggestionPanel {
    var onPick: ((Int, NSEvent.ModifierFlags) -> Void)?
    /// Pointer over row (nil: left the rows), in screen points.
    var onHover: ((Int?, CGPoint) -> Void)?

    private let content = SuggestionCardView()
    private var rows: [SuggestionRowView] = []
    private(set) var overlay: OverlayHandle?

    var isVisible: Bool { overlay.map { !$0.isDismissed } ?? false }

    /// The card view (tests draw it).
    var cardView: NSView { content }

    /// Shows `suggestions` under `anchor` (the bar), clipped to `pane`.
    func show(_ suggestions: [BrowserSuggestion], highlighted: Int?, below anchor: NSView, pane: NSView, in window: NSWindow) {
        rows.forEach { $0.removeFromSuperview() }
        rows = suggestions.enumerated().map { index, suggestion in
            let row = SuggestionRowView(suggestion: suggestion)
            row.onClick = { [weak self] flags in self?.onPick?(index, flags) }
            row.onPointer = { [weak self] inside, pointer in self?.onHover?(inside ? index : nil, pointer) }
            row.isHighlighted = index == highlighted
            return row
        }
        rows.forEach { content.card.addSubview($0) }

        let anchorRect = anchor.convert(anchor.bounds, to: nil)
        let outset = OmnibarStyle.cardSideOutset
        let rowStep = OmnibarStyle.rowHeight + OmnibarStyle.rowGap
        let cardHeight = CGFloat(rows.count) * rowStep + OmnibarStyle.cardBottomPadding
        let cardWidth = anchorRect.width + 2 * outset
        content.setFrameSize(NSSize(width: cardWidth, height: cardHeight))
        content.cardFrame = NSRect(x: 0, y: 0, width: cardWidth, height: cardHeight)
        // Rows from the top, inset (4 at the sides, 2 above each).
        for (index, row) in rows.enumerated() {
            let top = cardHeight - OmnibarStyle.rowGap - CGFloat(index) * rowStep
            row.frame = NSRect(x: OmnibarStyle.rowSideInset, y: top - OmnibarStyle.rowHeight,
                               width: cardWidth - 2 * OmnibarStyle.rowSideInset, height: OmnibarStyle.rowHeight)
            // Icon and text line up with the bar's chip and text.
            row.leadingIconCenter = outset + OmnibarStyle.chipLeading + OmnibarStyle.chipSize / 2 - OmnibarStyle.rowSideInset
            row.textLeading = outset + OmnibarStyle.chipLeading + OmnibarStyle.chipSize + OmnibarStyle.textLeading - OmnibarStyle.rowSideInset
        }
        content.needsLayout = true
        // The card takes the omnibar's theme scope (its room or workspace).
        anchor.themeScope.fullStrength.root(content)

        let origin = NSRect(x: anchorRect.minX - outset, y: anchorRect.minY - cardHeight, width: cardWidth, height: cardHeight)
        let clip = pane.convert(pane.bounds, to: nil)
        if let overlay, !overlay.isDismissed, content.window?.parent === window {
            overlay.update(paneClip: clip)
            overlay.update(anchor: origin)
            return
        }
        overlay?.dismiss()
        let handle = WindowOverlayHost.host(for: window).present(
            // Red: the window layer, not the pane layer.
            content, options: OverlayOptions(kind: .attached, anchor: origin, layer: .window)
        )
        handle.onDismiss = { [weak self, weak handle] in
            if self?.overlay === handle { self?.overlay = nil }
        }
        overlay = handle
    }

    func highlight(_ index: Int?) {
        for (offset, row) in rows.enumerated() {
            row.isHighlighted = offset == index
        }
    }

    /// Rows on screen (tests).
    var rowViews: [SuggestionRowView] { rows }

    func dismiss() {
        let shown = overlay
        overlay = nil
        shown?.dismiss()
    }
}

/// Transparent panel content holding the card layer and its shadow.
final class SuggestionCardView: NSView {
    let card = NSView()
    var cardFrame: NSRect = .zero { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        card.wantsLayer = true
        card.layer?.cornerRadius = OmnibarStyle.cardCornerRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        card.layer?.masksToBounds = false
        card.layer?.shadowOpacity = 0.16
        card.layer?.shadowRadius = 8
        card.layer?.shadowOffset = CGSize(width: 0, height: -2)
        addSubview(card)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        card.frame = cardFrame
        // The shadow shape reaches above the panel top, so the seam with the
        // bar's card top shows no shadow edge.
        let shape = CGRect(x: 0, y: 0, width: cardFrame.width, height: cardFrame.height + 40)
        card.layer?.shadowPath = CGPath(roundedRect: shape, cornerWidth: OmnibarStyle.cardCornerRadius, cornerHeight: OmnibarStyle.cardCornerRadius, transform: nil)
        refresh()
    }

    /// The card never scrolls (at most 15 rows); the wheel must not reach
    /// the page under it either.
    override func scrollWheel(with event: NSEvent) {}

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        performWithTheme {
            card.layer?.backgroundColor = OmnibarStyle.cardFill.cgColor
        }
    }
}
