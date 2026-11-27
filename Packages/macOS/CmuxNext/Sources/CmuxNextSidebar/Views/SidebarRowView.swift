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
            // A row that is no longer selected stops running into the card at once (`flush-goo`).
            if !isSelected { runsIntoCard = false }
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
        layer?.cornerCurve = Metrics.tabCornerCurve // one curve with the tabs (`TabCornerCurve`)
        layer?.cornerRadius = fillCornerRadius
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The fill's corner is the tab's at the density now, read on every layout: set once at `init`, a row made at a
    /// roomier density kept that density's corner after a switch, nearly a pill on Compact's 20 pt row beside its 5 pt
    /// tabs (Lucas 2026-11-14: "the left sidebar tab becomes too circular ... match the sidebar item roundness to the
    /// tab roundness"). A density change lays every row out again (its height changes).
    /// `appearance.tabShape` rounded makes the fill a capsule, as the tabs are (``TabShape/fillCornerRadius(_:height:tabHeight:)``);
    /// a selected row that runs into the card (`flush-goo`) keeps its corners only on the side away from the content.
    override func layout() {
        super.layout()
        let radius = DesignSettings.shared.tabShape.fillCornerRadius(fillCornerRadius, height: bounds.height, tabHeight: Metrics.tabHeight)
        if layer?.cornerRadius != radius { layer?.cornerRadius = radius }
        let corners = shownCorners
        if layer?.maskedCorners != corners { layer?.maskedCorners = corners }
    }

    /// The fill's corner: the tab's at the density now. A row that draws no rounded fill (a section block) answers 0.
    var fillCornerRadius: CGFloat { SidebarStyle.rowCornerRadius }

    /// The selected row runs into the content card (`appearance.cornerFlush` flush-goo; the window's chrome decides,
    /// `SidebarListView.setSelectionRunsIntoCard`): it paints the content's fill (``Palette/folderTabFill``) square on
    /// the card's side, and the window's shade leaves out its shape out to the card, with the fillets that meet it.
    var runsIntoCard = false {
        didSet {
            guard runsIntoCard != oldValue else { return }
            fadesNextFill = false
            needsDisplay = true
            needsLayout = true
        }
    }

    /// The fill's rounded corners: all four, or under ``runsIntoCard`` the two away from the card (the sidebar's outer side).
    private var shownCorners: CACornerMask {
        guard runsIntoCard else { return [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner] }
        return DesignSettings.shared.sidebarSide == .right ? [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMinXMaxYCorner]
    }

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

    /// The controls a hover shows and clears by paint (`setHoverPainted`, HOVER COMMIT): a row's x, ⋮, Unpin and tree
    /// fold once they first showed. A cleared one (in the tree, at opacity 0) answers accessibility as a hidden one did:
    /// it is not among the row's children and the row posts a layout change when it clears or shows. (AppKit's hit
    /// test answers the row itself for a point on any of its controls, shown or cleared: fleet step 27165c46.)
    /// Another control at opacity 0 (the speaker that the shown controls cover) stays a child, as before.
    var hoverPaintedControls: [NSView] { [] }

    /// The hover controls a hover cleared (shown once, now at opacity 0).
    private var clearHoverControls: [NSView] { hoverPaintedControls.filter { !$0.isHidden && $0.alphaValue == 0 } }

    /// The view an accessibility element stands for (a control answers through its cell).
    private func accessibilityView(of element: Any?) -> NSView? { (element as? NSView) ?? (element as? NSCell)?.controlView }

    /// The stuck project header covers the row (`SidebarListView.updateVeiledRows`): it is no accessibility element and
    /// its controls leave the key view loop until it shows again, so VoiceOver and Tab reach the header over it, not a
    /// row nobody can see. A control made while it is covered (a workspace row makes close, more and Unpin on first show,
    /// `RowControlSlot`) leaves it too (`didAddSubview`). A control that had focus hands it to the list.
    var isVeiled = false {
        didSet {
            guard isVeiled != oldValue else { return }
            if isVeiled {
                for control in interactiveSubviews { veil(control) }
            } else {
                for control in veiledControls { control.refusesFirstResponder = false }
                veiledControls = []
            }
        }
    }
    /// The controls `isVeiled` took out of the key view loop (and only those: one that refused focus already stays so).
    private var veiledControls: [NSControl] = []

    private func veil(_ view: NSView) {
        guard let control = view as? NSControl, !control.refusesFirstResponder else { return }
        control.refusesFirstResponder = true
        veiledControls.append(control)
        if window?.firstResponder === control {
            FocusRoute(.system, "a sidebar row went under the stuck header").moveKeyboard(in: window, to: superview)
        }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if isVeiled { veil(subview) }
    }

    /// What `setAccessibilityElement(_:)` last asked for (NSView's default is no element). Kept here so a covered row
    /// answers no without asking `super` (the crash-class selector check), and answers it again when shown.
    private var wantsAccessibilityElement = false

    override func setAccessibilityElement(_ accessibilityElement: Bool) { wantsAccessibilityElement = accessibilityElement }

    override func isAccessibilityElement() -> Bool { !isVeiled && wantsAccessibilityElement }

    override func accessibilityChildren() -> [Any]? {
        if isVeiled { return [] }
        guard let children = super.accessibilityChildren() else { return nil }
        let clear = clearHoverControls
        guard !clear.isEmpty else { return children }
        return children.filter { child in !clear.contains { $0 === accessibilityView(of: child) } }
    }

    /// A hover control cleared or showed (`setHoverPainted`): VoiceOver's view of the row changed, as when the control
    /// hid or showed. Marks that are no accessibility element (the badge, the keycap) post nothing.
    func hoverControlReachChanged(_ control: NSView) {
        guard hoverPaintedControls.contains(where: { $0 === control }) else { return }
        postAccessibility(self, .layoutChanged, [.uiElements: [control.alphaValue > 0 ? control : self]])
    }

    /// Posts an accessibility notification for the row: AppKit's `NSAccessibility.post`; a test records the posts.
    final var postAccessibility: @MainActor @Sendable (Any, NSAccessibility.Notification, [NSAccessibility.NotificationUserInfoKey: Any]?) -> Void = {
        NSAccessibility.post(element: $0, notification: $1, userInfo: $2)
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
        // A selected row that runs into the card shows the content's own fill, as the folder tab does.
        let shown = runsIntoCard && isSelected && color != nil ? Palette.folderTabFill ?? color : color
        ChromeHover.paint(layer, shown, animated: fadesNextFill, clearing: .hoverOut)
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
    /// The frame as drawn now, where a new group line starts (`groupLines(current:)`): mid-move the presentation (a
    /// render-server move sets the model frame to its end at once, `SidebarDragSpring`), else the model frame (a
    /// recycled layer's presentation can still show its last row's).
    var drawnFrame: CGRect { layer?.animationKeys()?.isEmpty == false ? shownFrame : frame }

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

/// An empty section's row: it draws nothing, as classic draws nothing there
/// (https://github.com/manaflow-ai/cmux/issues/32728), and stays only as the list's drop target. Pinned's drop zone says
/// nothing either (plans/cmux-next/ui-simplify.md, Pin: "no drop overlay text"): the gap a drag opens there is the cue.
final class EmptySectionRowView: SidebarRowView {}
