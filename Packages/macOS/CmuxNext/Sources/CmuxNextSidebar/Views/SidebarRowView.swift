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
            // A row lays its controls out again when its selection changes (cx-fo2t).
            needsLayout = true
        }
    }

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
    /// Where the title's first glyph starts on its baseline (the pen origin), in this row's
    /// coordinates: inline rename puts the editor's text exactly there, so nothing moves as
    /// editing starts. Nil: the row has no title to edit.
    @objc dynamic var titlePenOrigin: NSValue? { nil }
    /// The title's ink: the editor's text keeps it.
    @objc dynamic var titleInk: NSColor? { nil }
    /// Where the rename editor may end, in this row's coordinates.
    @objc dynamic var titleEditMaxX: CGFloat { bounds.width - Metrics.space3 }

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
    /// Invalidates a previous close's completion when the view parks before that close finishes.
    var reuseGeneration = 0
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
    private let hint = SidebarRowView.label(font: SidebarStyle.subtitleFont)

    required init(key: SidebarRowKey) {
        super.init(key: key)
        // Left-aligned where a workspace's title would start, so the empty
        // list reads as the list's first line, not a caption floating in
        // the middle of an empty column.
        label.alignment = .natural
        hint.alignment = .natural
        [label, hint].forEach(addSubview)
    }

    func configure(pinned: Bool, shortcut: String?) { // a document Pinned too (`.custom(sec_pinned)`, SidebarListView.configure)
        label.setString(pinned ? Strings.pinnedEmpty : Strings.sectionEmpty)
        label.setFont(SidebarStyle.subtitleFont)
        hint.setString(Strings.sectionEmptyHint(shortcut: shortcut))
        hint.setFont(SidebarStyle.subtitleFont)
        hint.isHidden = pinned
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        let x = SidebarStyle.titleLeading - SidebarStyle.labelCellPadding
        let width = max(0, b.width - x - Metrics.space2)
        let titleHeight = ceil(label.intrinsicContentSize.height)
        guard !hint.isHidden else {
            label.frame = NSRect(x: x, y: (b.height - titleHeight) / 2, width: width, height: titleHeight)
            hint.frame = .zero
            needsDisplay = true
            return
        }
        let hintHeight = ceil(hint.intrinsicContentSize.height)
        let lineGap = Metrics.space1
        let stackHeight = titleHeight + lineGap + hintHeight
        let top = (b.height - stackHeight) / 2
        label.frame = NSRect(x: x, y: top, width: width, height: titleHeight)
        hint.frame = NSRect(x: x, y: top + titleHeight + lineGap, width: width, height: hintHeight)
        needsDisplay = true
    }

    override func updateLayer() {
        performWithTheme {
            label.setColor(Palette.textTertiary)
            hint.setColor(Palette.textSecondary)
        }
    }
}
