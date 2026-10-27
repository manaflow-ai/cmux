import AppKit
import CmuxNextDesign
import CmuxNextInput
import CmuxNextWakeups
import QuartzCore

/// The lower part of the suggestion card: flush under the bar, as wide as
/// the bar (`OmnibarCardTopView`), rounded at the bottom only (flush above
/// a bar at the bottom of its pane and rounded at the top, `upward`), with
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
    /// The bar's window rect the card was last placed at, and on which side,
    /// so a later layout can tell whether the card must move (`follow`).
    private var placedAnchor: NSRect?
    private var placedUpward = false
    /// The theme scope the card is rooted in (`place`).
    private weak var rootedScope: ThemeScope?

    var isVisible: Bool { overlay.map { !$0.isDismissed } ?? false }

    /// The card view (tests draw it).
    var cardView: NSView { content }

    /// Row views made so far (tests: typing reuses them).
    private(set) var rowViewsMade = 0

    /// Site icons for page rows (`AddressBarView.rowFavicon`).
    var faviconSource: ((URL) async -> NSImage?)? {
        didSet { rows.forEach { $0.faviconSource = faviconSource } }
    }

    /// Every row's moves, enters and exits, on the card's one consumer: a delivery reports the row under
    /// the latest point, or none, where the rows are now (a typed character can reorder them between the
    /// move and the frame).
    private(set) lazy var hoverMoves = PointerFrameHover(owner: "OmniboxSuggestionPanel.hover", view: content) { [weak self] point in
        self?.pointerMoved(toWindowPoint: point)
    }

    /// One hover delivery at `windowPoint` (the card's window): the row under it, or nil off the rows.
    private func pointerMoved(toWindowPoint windowPoint: CGPoint) {
        let local = content.card.convert(windowPoint, from: nil)
        let row = rows.firstIndex { $0.frame.contains(local) }
        onHover?(row, content.window?.convertPoint(toScreen: windowPoint) ?? NSEvent.mouseLocation)
    }

    /// The windows' frame-aligned pointer input (feature `pointerFrameHover`): the rows hover on a frame
    /// interval's first move and once more at its frame, at the latest point. Nil: each move.
    var hoverFrameInput: FrameInputCoalescers? {
        get { hoverMoves.frames }
        set { hoverMoves.frames = newValue }
    }

    /// Shows `suggestions` under `anchor` (the bar), or above it when `upward`, clipped to `pane`.
    /// Rows already on the card take the new matches in place, so typing
    /// never rebuilds the card (no flash, hover tracking kept); only a
    /// longer list adds rows and a shorter one removes the extra ones.
    func show(_ suggestions: [BrowserSuggestion], highlighted: Int?, at anchor: NSView, upward: Bool = false, pane: NSView, in window: NSWindow) {
        let count = rows.count
        if count > suggestions.count {
            rows[suggestions.count...].forEach { $0.removeFromSuperview() }
            rows.removeLast(count - suggestions.count)
        }
        for (index, suggestion) in suggestions.enumerated() {
            if index < rows.count {
                rows[index].show(suggestion)
            } else {
                let row = SuggestionRowView(suggestion: suggestion, faviconSource: faviconSource)
                rowViewsMade += 1
                row.onClick = { [weak self] flags in self?.onPick?(index, flags) }
                row.frameInputHover = hoverMoves
                rows.append(row)
                content.card.addSubview(row)
            }
            rows[index].isHighlighted = index == highlighted
        }
        if rows.count != count { content.setAccessibilityRows(rows) }
        content.hoverMoves = hoverMoves
        place(at: anchor, upward: upward, pane: pane, in: window)
    }

    /// Sizes the card and its rows to `anchor` (the bar) and puts it under
    /// it (above it when `upward`): presented when it is not on screen, else moved in place.
    private func place(at anchor: NSView, upward: Bool, pane: NSView, in window: NSWindow) {
        let anchorRect = anchor.convert(anchor.bounds, to: nil)
        placedAnchor = anchorRect
        placedUpward = upward
        let outset = OmnibarStyle.cardSideOutset
        let rowStep = OmnibarStyle.rowHeight + OmnibarStyle.rowGap
        let cardHeight = CGFloat(rows.count) * rowStep + OmnibarStyle.cardBottomPadding
        let cardWidth = anchorRect.width + 2 * outset
        // Each typed character places the card again; what did not move asks for no layout or paint.
        let size = NSSize(width: cardWidth, height: cardHeight)
        if content.frame.size != size { content.setFrameSize(size) }
        content.cardFrame = NSRect(origin: .zero, size: size)
        content.opensUpward = upward
        content.cornerRadius = OmnibarStyle.cardCornerRadius
        // Rows from the top, inset (4 at the sides, 2 above each).
        for (index, row) in rows.enumerated() {
            let top = cardHeight - OmnibarStyle.rowGap - CGFloat(index) * rowStep
            let frame = NSRect(x: OmnibarStyle.rowSideInset, y: top - OmnibarStyle.rowHeight,
                               width: cardWidth - 2 * OmnibarStyle.rowSideInset, height: OmnibarStyle.rowHeight)
            if row.frame != frame { row.frame = frame }
            // Icon and text line up with the bar's chip and text.
            row.leadingIconCenter = outset + OmnibarStyle.chipLeading + OmnibarStyle.chipSize / 2 - OmnibarStyle.rowSideInset
            row.textLeading = outset + OmnibarStyle.chipLeading + OmnibarStyle.chipSize + OmnibarStyle.textLeading - OmnibarStyle.rowSideInset
            row.cornerRadius = OmnibarStyle.rowCornerRadius
        }
        // The card takes the omnibar's theme scope (its room or workspace). Rooting repaints every
        // view under the card (`ThemeRepaint`), so only a new scope roots it; the scope repaints
        // its roots itself when its colors change.
        let scope = anchor.themeScope.fullStrength
        if scope !== rootedScope {
            rootedScope = scope
            scope.root(content)
        }

        let origin = NSRect(x: anchorRect.minX - outset, y: upward ? anchorRect.maxY : anchorRect.minY - cardHeight, width: cardWidth, height: cardHeight)
        let clip = pane.convert(pane.bounds, to: nil)
        if let overlay, !overlay.isDismissed, content.window?.parent === window {
            overlay.update(paneClip: clip)
            overlay.update(anchor: origin)
            return
        }
        overlay?.dismiss()
        let handle = WindowOverlayHost.host(for: window).present(
            content, options: OverlayOptions(kind: .attached, anchor: origin, layer: .pane(clip: clip))
        )
        handle.onDismiss = { [weak self, weak handle] in
            if self?.overlay === handle { self?.overlay = nil }
        }
        overlay = handle
    }

    /// Moves and resizes the open card when `anchor` moved since it was
    /// placed (a window resize, or a toolbar render that lands after the
    /// rows). The row views stay, so a hovered row keeps its tracking.
    func follow(at anchor: NSView, upward: Bool = false, pane: NSView, in window: NSWindow) {
        guard isVisible, let placedAnchor, anchor.convert(anchor.bounds, to: nil) != placedAnchor || upward != placedUpward else { return }
        place(at: anchor, upward: upward, pane: pane, in: window)
    }

    func highlight(_ index: Int?) {
        var changed = false
        for (offset, row) in rows.enumerated() {
            changed = changed || row.isHighlighted != (offset == index)
            row.isHighlighted = offset == index
        }
        if changed {
            NSAccessibility.post(element: content.card, notification: .selectedChildrenChanged)
        }
    }

    /// Rows on screen (tests).
    var rowViews: [SuggestionRowView] { rows }

    func dismiss() {
        // The rows stay (the card fades out with them; the next show reuses them).
        let presented = overlay
        overlay = nil
        placedAnchor = nil
        presented?.dismiss()
    }
}

/// Transparent panel content holding the card layer and its shadow.
final class SuggestionCardListView: NSView {
    private var accessibilityRows: [SuggestionRowView] = []

    func setAccessibilityRows(_ rows: [SuggestionRowView]) {
        accessibilityRows = rows
    }

    override func accessibilitySelectedChildren() -> [Any]? {
        accessibilityRows.filter { $0.isAccessibilitySelected() }
    }
}

final class SuggestionCardView: NSView {
    let card = SuggestionCardListView()
    var cardFrame: NSRect = .zero { didSet { if cardFrame != oldValue { needsLayout = true } } }
    /// Above the bar: rounded at the top, not the bottom.
    var opensUpward = false { didSet { if opensUpward != oldValue { needsLayout = true } } }
    /// The bar's corner (it follows the look live), set at each placement.
    var cornerRadius: CGFloat = 0 { didSet { if cornerRadius != oldValue { needsLayout = true } } }
    /// The rows' hover consumer (``OmniboxSuggestionPanel/hoverMoves``): the pointer leaving the card is
    /// discrete, so its pending move lands then (`ShouldFlushQueue`).
    weak var hoverMoves: PointerFrameHover?
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // The transparent host is layout-only. The card is the AX list so
        // VoiceOver can enter the suggestion popup and move through rows.
        setAccessibilityElement(false)
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.list)
        wantsLayer = true
        layer?.masksToBounds = false
        card.wantsLayer = true
        card.layer?.cornerCurve = .continuous
        card.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        card.layer?.masksToBounds = false
        // No shadow of its own: the card top's shadow reaches down past the seam (OmnibarCardTopView).
        // This panel floats over the bar, so a shadow here that reached up to meet it would darken
        // the bar; one that stops at the seam shows a gap. A rows shadow needs a cut-out like
        // PopupHostView's and a device check (cx-iif6y follow-up).
        addSubview(card)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        card.frame = cardFrame
        card.layer?.maskedCorners = opensUpward ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        card.layer?.cornerRadius = cornerRadius
        refresh()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeForHover, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {}
    override func mouseExited(with event: NSEvent) { hoverMoves?.flush() }

    /// The card never scrolls (at most 15 rows); the wheel must not reach
    /// the page under it either.
    // input-coalesce: native (it drops the wheel; nothing runs to coalesce)
    override func scrollWheel(with event: NSEvent) {}

    // visibility-walk-allow: one layer color store in the theme scope, no layout or text measure; cheaper than a deferral
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    func setAccessibilityRows(_ rows: [SuggestionRowView]) {
        card.setAccessibilityRows(rows)
        card.setAccessibilityChildren(rows)
        rows.forEach { $0.setAccessibilityParent(card) }
    }

    private func refresh() {
        performWithTheme {
            card.layer?.backgroundColor = OmnibarStyle.cardFill.cgColor
        }
    }
}
