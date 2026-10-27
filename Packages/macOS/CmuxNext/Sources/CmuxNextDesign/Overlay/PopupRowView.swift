public import AppKit
public import CmuxNextInput

/// The one native popup row (hq `.cmux-scratch/omnibar-popups/REUSE.md` slice 2): the page menus
/// past the window's edge (``WebPopupHost``), the Extensions menu and the Page Info bubble draw
/// their rows with it, so a row looks and behaves the same in every native popup.
///
/// A row is a leading column (an icon or a check mark), a title with an optional subtitle, and an
/// optional trailing view (a shortcut, a chevron, a toggle, buttons). The row owns the states
/// every popup shares: the gray highlight in the popup row radius (``PopupStyle``), a press fill,
/// a gray keyboard focus ring (never the system accent), hover tracking, a click (release inside
/// the row), Return / Enter / Space when it has the keys, and the accessibility press.
@MainActor
open class PopupRowView: NSView {
    /// Where the columns sit. The defaults are the page menu's row.
    public struct Layout {
        /// Space before the leading column, and after the trailing view.
        public var leading: CGFloat = 7
        public var trailing: CGFloat = 8
        /// The leading column's width (icon or check mark); 0 for none.
        public var leadingColumn: CGFloat = 15
        /// Space between the leading column and the title.
        public var gap: CGFloat = 0
        /// Space between the title and the trailing view (a shortcut keeps a wide gap).
        public var trailingGap: CGFloat = 12
        public var minHeight: CGFloat = PopupStyle.standard.rowHeight
        /// The highlight's inset from the row's bounds.
        public var fillInset = NSSize.zero
        /// The pointer over the row draws the highlight. Off when the owner drives the one
        /// highlight itself (a menu that the keyboard and the pointer share): ``onHover`` reports
        /// the pointer.
        public var hoverFills = true

        public init() {}
    }

    public let rowLayout: Layout
    public let titleLabel = ThemedLabel(labelWithString: "")
    public let subtitleLabel = ThemedLabel(labelWithString: "")
    public let leadingView: NSView?
    public let trailingView: NSView?
    /// A click, Return / Enter / Space, or the accessibility press.
    public var onActivate: (() -> Void)?
    /// The pointer moved onto the row (enabled interactive rows only).
    public var onHover: (() -> Void)?
    /// The popup's one hover consumer (feature `pointerFrameHover`): the row's moves, enters and exits
    /// go to it, and its delivery calls ``pointerMoved()`` on the row under the latest point, at most
    /// twice a frame for the whole popup (Chromium's rAF-aligned moves, main_thread_event_queue.cc; its
    /// boundary events come from those moves, boundary_event_dispatcher.cc). A press flushes it first;
    /// the popup flushes it when the pointer leaves the popup. Nil: each enter and move acts at once.
    public weak var hoverMoves: PointerFrameHover?
    /// The owner's highlight (the keyboard's row in a menu).
    public var isHighlighted = false { didSet { if oldValue != isHighlighted { needsDisplay = true } } }
    public var isEnabled = true {
        didSet {
            titleLabel.ink = isEnabled ? .primary : .tertiary
            (leadingView as? ThemedLabel)?.ink = isEnabled ? .primary : .tertiary
            if isEnabled != oldValue { needsDisplay = true }
        }
    }
    /// The row takes the keys (Tab, arrows) and draws the focus ring when it has them.
    public var takesFocus = false
    public let isInteractive: Bool

    private var isHovering = false { didSet { if oldValue != isHovering { needsDisplay = true } } }
    private var isPressed = false { didSet { if oldValue != isPressed { needsDisplay = true } } }
    private var showsFocus = false { didSet { if oldValue != showsFocus { needsDisplay = true } } }
    private var tracking: NSTrackingArea?
    /// The highlight, press fill and focus ring: layer properties in the popup row radius, inset by
    /// ``Layout/fillInset``; the row draws no backing store.
    let highlight = ChromeFillLayer()

    public init(leading: NSView?, title: String, subtitle: String? = nil, trailing: NSView? = nil,
                layout: Layout = Layout(), interactive: Bool = true) {
        rowLayout = layout
        leadingView = leading
        trailingView = trailing
        isInteractive = interactive
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: layout.minHeight))
        focusRingType = .none
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        highlight.cornerRadius = PopupStyle.standard.rowCornerRadius
        highlight.isHidden = true
        layer?.insertSublayer(highlight, at: 0)
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle ?? ""
        for (label, font, ink) in [(titleLabel, Typography.body, ThemeInk.primary), (subtitleLabel, Typography.caption, .secondary)] {
            label.font = font
            label.ink = ink
            label.lineBreakMode = .byTruncatingTail
            label.truncatesLastVisibleLine = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        subtitleLabel.isHidden = subtitle?.isEmpty ?? true
        let texts = NSStackView(views: [titleLabel, subtitleLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        for view in [leading, texts, trailing].compactMap(\.self) {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let textLeading = layout.leading + layout.leadingColumn + (layout.leadingColumn > 0 ? layout.gap : 0)
        var constraints = [
            heightAnchor.constraint(greaterThanOrEqualToConstant: layout.minHeight),
            texts.leadingAnchor.constraint(equalTo: leadingAnchor, constant: textLeading),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
            texts.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
        ]
        if let leading {
            constraints += [
                leading.centerXAnchor.constraint(equalTo: leadingAnchor, constant: layout.leading + layout.leadingColumn / 2),
                leading.centerYAnchor.constraint(equalTo: centerYAnchor),
                leading.widthAnchor.constraint(lessThanOrEqualToConstant: max(layout.leadingColumn, 1)),
            ]
        }
        if let trailing {
            trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
            constraints += [
                trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -layout.trailing),
                trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
                fits(texts.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -layout.trailingGap)),
            ]
        } else {
            constraints.append(fits(texts.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -layout.trailing)))
        }
        NSLayoutConstraint.activate(constraints)
        setAccessibilityElement(true)
        setAccessibilityRole(interactive ? .button : .staticText)
        setAccessibilityLabel([title, subtitle].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: ", "))
    }

    /// The title's end yields while the row is narrower than its columns (a panel not yet sized).
    private func fits(_ constraint: NSLayoutConstraint) -> NSLayoutConstraint {
        constraint.priority = .defaultHigh
        return constraint
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Parts

    /// A check mark for the leading column (a menu's checked row); hidden when `checked` is false.
    public static func checkMark(_ checked: Bool) -> NSView {
        let mark = ThemedLabel(labelWithString: "✓")
        mark.font = Typography.body
        mark.isHidden = !checked
        return mark
    }

    /// A shortcut for the trailing view, in the quiet text color.
    public static func shortcut(_ text: String) -> NSView {
        let label = ThemedLabel(labelWithString: text)
        label.font = Typography.body
        label.ink = .tertiary
        return label
    }

    /// The row and its parts leave the accessibility tree (an owner that keeps its own, a page).
    public func hideFromAccessibility() {
        for view in ([self, titleLabel, subtitleLabel, leadingView, trailingView] as [NSView?]).compactMap(\.self) { view.setAccessibilityElement(false) }
    }

    // MARK: States

    /// The row draws the highlight: the owner's, the pointer's, or a subclass's (a menu item's).
    open var drawsHighlight: Bool {
        guard isEnabled, isInteractive else { return false }
        return isHighlighted || showsFocus || (rowLayout.hoverFills && isHovering)
    }

    nonisolated open override var wantsUpdateLayer: Bool { true }

    /// The fill for the state, and the focus ring as the fill's border (a 1.5 pt line inside its edge).
    open override func updateLayer() {
        let pressed = isPressed && isEnabled && isInteractive
        guard pressed || drawsHighlight else {
            highlight.isHidden = true
            return
        }
        let focused = showsFocus
        let (fill, ring): (CGColor, CGColor?) = performWithTheme {
            ((pressed ? Palette.pressedFill : Palette.hoverFill).cgColor, focused ? Palette.focusRing.cgColor : nil)
        }
        highlight.backgroundColor = fill
        highlight.borderColor = ring
        highlight.borderWidth = focused ? Metrics.lineWidth(1.5) : 0
        placeHighlight()
        highlight.isHidden = false
    }

    open override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        if newSize != oldSize { placeHighlight() }
    }

    private func placeHighlight() {
        highlight.frame = bounds.insetBy(dx: rowLayout.fillInset.width, dy: rowLayout.fillInset.height)
    }

    open override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true // invalidate: the appearance changed; the colors resolve again.
    }

    // MARK: Pointer

    open override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        guard isInteractive else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    // Crossing into or out of a row is a position like a move: with a popup consumer it coalesces with the
    // moves around it, so a sweep across the rows hovers at most twice a frame. A press is discrete: the
    // popup's pending move lands first (`ShouldFlushQueue`).
    open override func mouseEntered(with event: NSEvent) {
        isHovering = true
        if let hoverMoves { hoverMoves.crossed(event) } else if isEnabled { onHover?() }
    }

    open override func mouseMoved(with event: NSEvent) {
        if let hoverMoves { hoverMoves.moved(event) } else { pointerMoved() }
    }

    /// The pointer moved over the row (a move, or the popup's frame delivery of one): the keyboard
    /// moved the highlight away while the pointer stayed, so the move takes it back.
    public func pointerMoved() {
        if isEnabled, !isHighlighted { onHover?() }
    }

    open override func mouseExited(with event: NSEvent) {
        hoverMoves?.crossed(event)
        isHovering = false
        isPressed = false
    }

    open override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    open override func mouseDown(with event: NSEvent) {
        hoverMoves?.flush()
        guard isInteractive else { return super.mouseDown(with: event) }
        isPressed = true
    }

    /// A release inside the row activates it, also after a press elsewhere (a menu dragged open).
    open override func mouseUp(with event: NSEvent) {
        isPressed = false
        guard isInteractive, isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        activate()
    }

    /// Runs ``onActivate`` (subclasses add their own default, a toggle's flip).
    open func activate() { onActivate?() }

    // MARK: Keys

    open override var acceptsFirstResponder: Bool { takesFocus && isInteractive }
    open override var canBecomeKeyView: Bool { takesFocus && isInteractive }

    open override func becomeFirstResponder() -> Bool {
        showsFocus = true
        return super.becomeFirstResponder()
    }

    open override func resignFirstResponder() -> Bool {
        showsFocus = false
        return super.resignFirstResponder()
    }

    open override func keyDown(with event: NSEvent) {
        // Return, Enter, Space.
        guard [36, 76, 49].contains(event.keyCode), isEnabled else { return super.keyDown(with: event) }
        activate()
    }

    open override func accessibilityPerformPress() -> Bool {
        guard isInteractive, isEnabled else { return false }
        activate()
        return true
    }
}
