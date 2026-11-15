public import AppKit

/// A clickable + of its own: the window's standard + (``PlusButtonLook``) in an `NSButton`, for an add control
/// outside the tab bar and the sidebar (Home's Add Recipient). Target and action, the keyboard and VoiceOver work as
/// for any button; hover and press show the + look's fill and ink.
public final class PlusButton: ClickableButton {
    public private(set) lazy var look = PlusButtonLook(host: self)
    private lazy var pointer = PointerHover(self) { [weak self] _ in self?.applyState(animated: true) }
    private var isHeld = false

    /// - Parameter label: What the + adds, for VoiceOver and the tooltip.
    public init(label: String) {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        imagePosition = .noImage
        focusRingType = .none
        wantsLayer = true
        setAccessibilityLabel(label)
        themedToolTip = label
        _ = look
        _ = pointer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The trailing column's square: the top row's button side.
    public override var intrinsicContentSize: NSSize { NSSize(width: TopRowSpacing.buttonSide, height: TopRowSpacing.buttonSide) }

    public nonisolated override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() { look.refresh() }

    public override func layout() {
        super.layout()
        look.layout(in: bounds, scale: window?.backingScaleFactor ?? 2)
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        look.refresh()
    }

    /// A button hidden under a still pointer gets no exit event: the pointer hover clears it.
    public override func viewDidHide() {
        super.viewDidHide()
        isHeld = false
        pointer.refresh()
        applyState(animated: false)
    }

    /// NSButton tracks the click inside `super.mouseDown` and returns on release.
    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return super.mouseDown(with: event) }
        isHeld = true
        applyState(animated: false)
        super.mouseDown(with: event)
        isHeld = false
        applyState(animated: false)
    }

    private func applyState(animated: Bool) {
        look.apply(.init(hovering: pointer.isHovering, pressed: isHeld), animated: animated)
    }
}
