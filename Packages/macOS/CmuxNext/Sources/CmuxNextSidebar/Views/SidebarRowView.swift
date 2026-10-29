import AppKit
import CmuxNextDesign
import QuartzCore

/// Base class for every row. Rows are passive: the list view owns mouse
/// handling, hover, and drag, so rows return nil from hit testing except for
/// their own buttons.
class SidebarRowView: NSView {
    var key: SidebarRowKey
    var isHovered = false { didSet { if isHovered != oldValue { hoverChanged() } } }
    /// The row is the sidebar's selected item and paints the selection fill.
    /// A selection change paints at once, never fades or travels
    /// (SIDEBAR-SELECTION-NO-TRAVEL-ANIMATION); hover alone fades.
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            updateAccessibilitySelection()
            fadesNextFill = false
            needsDisplay = true
            // Rows show controls on the selected row too (the tab chevron, cx-fo2t).
            needsLayout = true
        }
    }

    /// The move whose tuck fade this tab line runs (`RowMotion.tuck`), so an older move's end leaves a newer one's.
    var tuckMove: Int?

    /// The row shows as selected, the one source of its AXSelected. A row with more
    /// selection state overrides it and calls `updateAccessibilitySelection()` when that changes.
    var showsSelection: Bool { isSelected }

    func updateAccessibilitySelection() { setAccessibilitySelected(showsSelection) }

    required init(key: SidebarRowKey) {
        self.key = key
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = SidebarStyle.rowCornerRadius
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        // A button fading out after hover shows but takes no click.
        for button in interactiveSubviews where !button.isHidden && button.alphaValue > 0 && button.frame.contains(local) {
            return button
        }
        return nil
    }

    /// Fingerprint of the last configured content. Reloads happen on every
    /// drag step, so rows skip work (symbol images, attributed strings,
    /// accessibility) when nothing they show has changed.
    var configuredContent: AnyHashable?

    /// Returns false when `content` matches the last configuration.
    func needsConfigure(_ content: AnyHashable) -> Bool {
        guard content != configuredContent else { return false }
        configuredContent = content
        return true
    }

    /// A view that comes back to its own row keeps its configured content, so the
    /// row's next `configure` with equal content changes nothing and its text
    /// layers keep their drawing (scroll back over parked rows, perf round 4).
    /// Rows whose configure sets state that this reset clears (a tooltip) say no.
    class var keepsContentOnReturn: Bool { false }

    /// Resets transient state before a recycled view shows another row.
    func prepareForReuse(key: SidebarRowKey) {
        if !(key == self.key && Self.keepsContentOnReturn) { configuredContent = nil }
        self.key = key
        isHovered = false
        isSelected = false
        // A recycled row shows its new content's fill at once.
        fadesNextFill = false
        fadesNextHover = false
        // A row parked mid-move does not finish that move when it comes back (cx-bqm6).
        layer?.removeAllAnimations()
        layer?.zPosition = 0 // a tab line parked mid-tuck (`RowMotion.tuck`) draws in order again
        tuckMove = nil
        clipsToBounds = false
        targetSize = nil
        alphaValue = 1
        setTitleHidden(false)
        themedToolTip = nil
        // A view that kept its content skips configure: it still paints once more, for a theme that
        // changed while it was out of the window (a lift). Labels redraw only on a changed value.
        needsDisplay = true
    }

    /// Buttons that receive clicks directly.
    var interactiveSubviews: [NSView] { [] }

    /// Frame of the title text in this row's coordinates, for inline rename.
    @objc dynamic var titleFrame: NSRect { .zero }
    @objc dynamic var titleFont: NSFont { SidebarStyle.titleFont }
    @objc dynamic func setTitleHidden(_ hidden: Bool) {}

    @objc dynamic func hoverChanged() {
        // Hover entry is immediate; clearing a row's fill uses the `hoverOut` token (instant by
        // default). Its hover controls clear at once too: a pointer moving to the next row never
        // leaves the old row's buttons behind (Leo 2026-10-20: no exit delay on hover-out).
        fadesNextFill = !isHovered
        fadesNextHover = false
        needsDisplay = true
    }

    /// Clears hover state before a row leaves the realized list. This avoids
    /// carrying its fill or hover controls through the close/recycle motion.
    func clearHoverImmediately() {
        isHovered = false
        fadesNextFill = false
        fadesNextHover = false
        needsDisplay = true
        needsLayout = true
    }

    /// The next fill change came from hover. Hover entry is immediate and the
    /// default hover-out token clears it without leaving a trail.
    var fadesNextFill = false
    /// The next layout came from hover: the row's hover controls reveal or
    /// clear in place (the row's `layout()` clears it).
    var fadesNextHover = false

    /// Paints `color` on the row's backing layer, fading when hover changed
    /// it. Call from `updateLayer()` inside the theme scope.
    func paintFill(_ color: NSColor?) {
        paintsFill = color != nil
        guard let layer else { return }
        ChromeHover.paint(layer, color, animated: fadesNextFill, clearing: .hoverOut)
        fadesNextFill = false
    }

    /// The row paints a fill now (`paintFill`); debug.sidebar_rows `fill`.
    private(set) var paintsFill = false
    /// Any fill the row shows now, its own or a part's (debug).
    var debugFill: Bool { paintsFill }
    /// The row's disclosure chevron for debug.sidebar_rows: the pack icon it
    /// draws, its frame in the row and whether it shows; nil without one.
    var debugDisclosure: (icon: String, frame: CGRect, shown: Bool)? { nil }
    /// The leading icon the row's view draws now for debug.sidebar_rows `icon`
    /// (`symbol`, `swatch`, `emoji`, `favicon`, `agentMark`); nil when it draws none.
    var debugIcon: String? { nil }
    /// The row draws the archived look (plans/cmux-next/archiving-DESIGN.md).
    var debugArchived: Bool { false }
    /// The address of the favicon the row draws (a link row), for proofs.
    var debugIconAddress: String? { nil }

    /// Counts the times this row started opening its slot (clipped): an
    /// earlier open's completion, run early when a later update reopens the
    /// row, leaves the later open's clip alone (cx-ai79).
    var opens = 0
    /// The frame a row that left the list closes its slot to, until its close recycles it
    /// (`RowMotion`): a viewport re-anchor mid-close shifts it with the rows (cx-y2uf5).
    var closingEnd: NSRect?

    /// The frame as drawn now: the presentation mid-animation (debug).
    var shownFrame: CGRect { layer?.presentation()?.frame ?? frame }

    /// Size the row is animating toward. Content lays out for the final size
    /// up front, so an animated frame change never shows a stale layout.
    var targetSize: NSSize? {
        didSet { if targetSize != oldValue { needsLayout = true } }
    }

    /// Bounds to lay out content in: the target size while animating.
    var layoutBounds: NSRect { NSRect(origin: .zero, size: targetSize ?? bounds.size) }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// A one-line label. Its color is set in the row's `updateLayer`, inside
    /// `performWithTheme`, so it follows the row's theme scope; it is a layer
    /// color, so a theme change blends it (`ChromeLabel`, I5).
    static func label(font: NSFont) -> ChromeLabel {
        ChromeLabel(font: font)
    }

    /// A one-line AppKit label for attributed text with its own run colors.
    static func attributedLabel(font: NSFont) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = font
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.truncatesLastVisibleLine = true
        return field
    }
}

// MARK: - Workspace

final class EmptySectionRowView: SidebarRowView {
    private let label = SidebarRowView.label(font: SidebarStyle.subtitleFont)

    required init(key: SidebarRowKey) {
        super.init(key: key)
        // Left-aligned where a workspace's title would start, so the empty
        // list reads as the list's first line, not a caption floating in
        // the middle of an empty column.
        label.alignment = .natural
        addSubview(label)
    }

    func configure(pinned: Bool) { // a document Pinned too (`.custom(sec_pinned)`, SidebarListView.configure)
        label.setString(pinned ? Strings.pinnedEmpty : Strings.sectionEmpty)
        label.setFont(SidebarStyle.subtitleFont)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        let h = ceil(label.intrinsicContentSize.height)
        let x = SidebarStyle.titleLeading - SidebarStyle.labelCellPadding
        label.frame = NSRect(x: x, y: (b.height - h) / 2, width: max(0, b.width - x - Metrics.space2), height: h)
        needsDisplay = true
    }

    override func updateLayer() {
        performWithTheme { label.setColor(Palette.textTertiary) }
    }
}
