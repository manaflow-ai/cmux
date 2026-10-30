public import AppKit
public import CmuxNextIcons

/// The app's one more ("overflow") button: a vertical ellipsis (⋮, the pack's `action.more.vertical`),
/// like Chrome's menu button (Leo 2026-10-20). Every more button uses it, so the glyph, its size and
/// the chrome's hover and pressed look are the same in the sidebar, pane toolbars and cards; the host
/// gives it the frame of its row of buttons and says what a press does.
public final class OverflowButton: ClickableButton {
    /// The glyph every more button draws.
    public static let glyph: IconName = .actionMoreVertical
    /// The glyph's point size, read at layout time so density changes apply live.
    public static var glyphSize: CGFloat { .iconRowSize(forLabelPointSize: Metrics.smallIconSize - Metrics.space1) }

    public private(set) lazy var hover = ChromeHover(self, behindContent: true)
    /// What a click or VoiceOver's press does (the sidebar row's menu, the group editor).
    public var onPress: (() -> Void)?
    /// A menu that opens on press, like a pop-up button (the pane toolbar's): press, drag to a row
    /// and release to run it. VoiceOver's press runs ``onPress``, else opens this menu.
    public var pressMenu: (() -> NSMenu?)?
    /// Shows a press menu under the button (tests record it instead).
    public var presentMenu: @MainActor (NSMenu, OverflowButton) -> Void = { menu, button in
        menu.popUp(positioning: nil, at: CmuxPopoverAnchor.menuPoint(in: button, gap: Metrics.space1), in: button)
    }
    /// The button's right-click menu; nil keeps AppKit's.
    public var menuProvider: (() -> NSMenu?)?
    /// A fixed glyph color on a colored surface (a group header's ink); nil uses the secondary
    /// text color, primary while hovered or pressed.
    public var tintOverride: NSColor? { didSet { if tintOverride != oldValue { needsDisplay = true } } }
    /// What the button opens, for VoiceOver and the themed tooltip.
    public var label: String {
        didSet {
            guard label != oldValue else { return }
            setAccessibilityLabel(label)
            themedToolTip = label
            image?.accessibilityDescription = label
        }
    }
    private var renderedSize: CGFloat = 0

    public init(label: String) {
        self.label = label
        super.init(frame: .zero)
        // An image-only button: no "Button" title for VoiceOver and hint mode (they read the label).
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        setAccessibilityLabel(label)
        themedToolTip = label
        wantsLayer = true
        target = self
        action = #selector(pressed)
        refusesFirstResponder = true
        focusRingType = .none
        renderGlyph()
        // Hover follows the pointer and the button's frame (cx-3wu5).
        hover.followPointer(onChange: { [weak self] in self?.needsDisplay = true })
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var mouseDownCanMoveWindow: Bool { false }

    @objc private func pressed() { onPress?() }

    /// AXPress runs `onPress` and reports success (NSButton's own press answered -25205, so an
    /// agent that read the error pressed again).
    override public func accessibilityPerformPress() -> Bool {
        guard onPress != nil || pressMenu != nil else { return super.accessibilityPerformPress() }
        guard isEnabled, !isHiddenOrHasHiddenAncestor else { return false }
        if let onPress {
            onPress()
        } else if let menu = pressMenu?(), !menu.items.isEmpty {
            presentMenu(menu, self)
        }
        return true
    }

    override public func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?() ?? super.menu(for: event)
    }

    private func renderGlyph() {
        let size = Self.glyphSize
        guard size != renderedSize else { return }
        renderedSize = size
        let image = NSImage.icon(Self.glyph, size: size)
        image.accessibilityDescription = label
        self.image = image
    }

    override public func layout() {
        super.layout()
        renderGlyph()
    }

    nonisolated override public var wantsUpdateLayer: Bool { true }

    override public func updateLayer() {
        layer?.cornerRadius = Metrics.itemCornerRadius
        performWithTheme {
            contentTintColor = tintOverride ?? (hover.state.hovering || hover.state.pressed ? Palette.textPrimary : Palette.textSecondary)
        }
        hover.refresh(animated: false)
    }

    private func changeHover(_ change: (inout ChromeHover.State) -> Void) {
        change(&hover.state)
        needsDisplay = true
    }

    /// A press menu opens on mouse-down, pressed while it is open; otherwise NSButton tracks the
    /// click inside `super.mouseDown` and returns on release.
    override public func mouseDown(with event: NSEvent) {
        guard isEnabled else { return super.mouseDown(with: event) }
        changeHover { $0.pressed = true }
        defer { changeHover { $0.pressed = false } }
        if let pressMenu {
            guard let menu = pressMenu(), !menu.items.isEmpty else { return }
            presentMenu(menu, self)
            return
        }
        super.mouseDown(with: event)
    }

    /// A button hidden under the pointer (a row's hover controls) gets no exit event: the hover
    /// owner clears it, and it shows again with the hover the pointer gives it then.
    override public func viewDidHide() {
        super.viewDidHide()
        changeHover { $0.pressed = false }
        hover.pointer?.refresh()
    }

    override public func viewDidUnhide() {
        super.viewDidUnhide()
        hover.pointer?.refresh()
    }
}
