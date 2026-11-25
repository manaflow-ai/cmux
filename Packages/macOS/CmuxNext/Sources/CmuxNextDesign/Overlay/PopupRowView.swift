public import AppKit

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
    /// The row's padded box: ``Layout/leading`` from its leading edge to ``Layout/trailing`` from
    /// its trailing edge. A control that spans the row or yields to it (a popup's slider) stays in it.
    public let contentGuide = NSLayoutGuide()
    public let titleLabel = ThemedLabel(labelWithString: "")
    public let subtitleLabel = ThemedLabel(labelWithString: "")
    public let leadingView: NSView?
    public let trailingView: NSView?
    /// A click, Return / Enter / Space, or the accessibility press.
    public var onActivate: (() -> Void)?
    /// The pointer moved onto the row (enabled interactive rows only).
    public var onHover: (() -> Void)?
    /// The owner's highlight (the keyboard's row in a menu).
    public var isHighlighted = false { didSet { if oldValue != isHighlighted { needsDisplay = true } } }
    public var isEnabled = true {
        didSet {
            titleLabel.ink = isEnabled ? .primary : .tertiary
            (leadingView as? ThemedLabel)?.ink = isEnabled ? .primary : .tertiary
            needsDisplay = true
        }
    }
    /// The row takes the keys (Tab, arrows) and draws the focus ring when it has them.
    public var takesFocus = false
    public let isInteractive: Bool

    private var isHovering = false { didSet { if oldValue != isHovering { needsDisplay = true } } }
    private var isPressed = false { didSet { if oldValue != isPressed { needsDisplay = true } } }
    private var showsFocus = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    public init(leading: NSView?, title: String, subtitle: String? = nil, trailing: NSView? = nil,
                layout: Layout = Layout(), interactive: Bool = true) {
        rowLayout = layout
        leadingView = leading
        trailingView = trailing
        isInteractive = interactive
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: layout.minHeight))
        focusRingType = .none
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
        addLayoutGuide(contentGuide)
        let textLeading = layout.leading + layout.leadingColumn + (layout.leadingColumn > 0 ? layout.gap : 0)
        var constraints = [
            heightAnchor.constraint(greaterThanOrEqualToConstant: layout.minHeight),
            contentGuide.leadingAnchor.constraint(equalTo: leadingAnchor, constant: layout.leading),
            contentGuide.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -layout.trailing),
            contentGuide.topAnchor.constraint(equalTo: topAnchor),
            contentGuide.bottomAnchor.constraint(equalTo: bottomAnchor),
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

    open override func draw(_ dirtyRect: NSRect) {
        let pressed = isPressed && isEnabled && isInteractive
        guard pressed || drawsHighlight else { return }
        let style = PopupStyle.standard
        let rect = bounds.insetBy(dx: rowLayout.fillInset.width, dy: rowLayout.fillInset.height)
        let path = NSBezierPath(roundedRect: rect, xRadius: style.rowCornerRadius, yRadius: style.rowCornerRadius)
        performWithTheme {
            (pressed ? Palette.pressedFill : Palette.hoverFill).setFill()
            path.fill()
            guard showsFocus else { return }
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: style.rowCornerRadius,
                                    yRadius: style.rowCornerRadius)
            ring.lineWidth = Metrics.lineWidth(1.5)
            Palette.focusRing.setStroke()
            ring.stroke()
        }
    }

    open override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
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

    open override func mouseEntered(with event: NSEvent) {
        isHovering = true
        if isEnabled { onHover?() }
    }

    open override func mouseMoved(with event: NSEvent) {
        // The keyboard moved the highlight away while the pointer stayed: a move takes it back.
        if isEnabled, !isHighlighted { onHover?() }
    }

    open override func mouseExited(with event: NSEvent) {
        isHovering = false
        isPressed = false
    }

    open override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    open override func mouseDown(with event: NSEvent) {
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
