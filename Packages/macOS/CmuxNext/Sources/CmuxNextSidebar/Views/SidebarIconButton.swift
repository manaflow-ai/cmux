import AppKit
import CmuxNextDesign
import CmuxNextIcons
import QuartzCore

/// Small borderless icon button with the shared chrome hover and pressed
/// fills (`ChromeHover`, no blue).
final class SidebarIconButton: ClickableButton {
    private(set) lazy var hover = ChromeHover(self, behindContent: true)
    var onPress: (() -> Void)?
    /// A fixed glyph color for a button on a colored surface (the group
    /// header's ink); nil uses the secondary text color, primary on hover.
    var tintOverride: NSColor? { didSet { if tintOverride != oldValue { needsDisplay = true } } }

    /// Replacing the icon or label redraws the button (a disclosure's chevron).
    var icon: IconName { didSet { if icon != oldValue { renderedSize = 0; renderIcon() } } }
    var label: String {
        didSet {
            guard label != oldValue else { return }
            setAccessibilityLabel(label)
            applyToolTip()
            renderedSize = 0
            renderIcon()
        }
    }
    /// Hovering shows the label as the themed tooltip. Off for a glyph that names itself (a card's
    /// ×, media controls), which keeps the label for VoiceOver only (Leo, 2026-10-20).
    var showsLabelToolTip = true {
        didSet { if showsLabelToolTip != oldValue { applyToolTip() } }
    }
    /// Full Keyboard Access reaches this button (a card's x, UPDATE-CARD-CLOSE): Tab focuses it,
    /// Space presses it, and the focus shows as a ring in the theme's focus color (cx-wqn5), not
    /// the system's blue ring. Off by default: most icon buttons have a keyboard path elsewhere.
    var takesKeyFocus = false {
        didSet { refusesFirstResponder = !takesKeyFocus }
    }
    private var isKeyFocused = false { didSet { if isKeyFocused != oldValue { needsDisplay = true } } }
    /// Mouse events never move the keyboard focus here: a click on a card's x would otherwise
    /// leave the focus on a button that the card then hides, and typing would go nowhere.
    private static let mouseEvents: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                                               .otherMouseDown, .otherMouseUp]
    private lazy var keyRepaint = KeyWindowRepaint(self)
    /// The label point size the icon sits beside, read at layout time so density changes apply live.
    private let pointSize: () -> CGFloat
    private var renderedSize: CGFloat = 0
    /// An SF Symbol drawn through the pack (`NSImage.icon(symbol:)`) for a glyph
    /// the pack has no name for, such as the group editor's emoji button.
    private var symbol: String?

    /// Replaces the SF Symbol a ``init(symbol:pointSize:label:)`` button draws.
    func setSymbol(_ name: String) {
        guard name != symbol else { return }
        symbol = name
        renderedSize = 0
        renderIcon()
    }

    init(icon: IconName, pointSize: @escaping () -> CGFloat = { Metrics.smallIconSize }, label: String) {
        self.icon = icon
        self.label = label
        self.pointSize = pointSize
        super.init(frame: .zero)
        // The image comes when the button first shows (``renderIcon()``): a row's hover controls stay hidden.
        imagePosition = .imageOnly
        // An image-only button: no "Button" title for VoiceOver and hint mode (they read the label).
        title = ""
        isBordered = false
        setAccessibilityLabel(label)
        defersThemedToolTipTracking = true
        applyToolTip()
        wantsLayer = true
        target = self
        action = #selector(pressed)
        refusesFirstResponder = true
        focusRingType = .none
        // Hover follows the pointer and the button's frame (cx-3wu5).
        hover.followPointer(onChange: { [weak self] in self?.needsDisplay = true })
    }

    convenience init(symbol: String, pointSize: @escaping () -> CGFloat = { Metrics.smallIconSize }, label: String) {
        self.init(icon: IconName(symbol), pointSize: pointSize, label: label)
        self.symbol = symbol
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pressed() { onPress?() }

    /// A first click in a window that is not key presses the button rather than only making the
    /// window key (a card's x over a page: a Chromium page's own window holds the key while the
    /// person works in a chat). Off by default, AppKit's answer.
    var takesFirstClick = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        takesFirstClick || super.acceptsFirstMouse(for: event)
    }

    /// AXPress runs `onPress` and reports success. NSButton's own press ran the action yet
    /// answered -25205 (kAXErrorActionUnsupported) for the sidebar's New Workspace, so a
    /// computer-use agent that read the error pressed again and made a second workspace.
    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return super.accessibilityPerformPress() }
        guard isEnabled, !isHiddenOrHasHiddenAncestor else { return false }
        onPress()
        return true
    }

    /// The button's right-click menu (cx-2lm4; the sidebar's New button shows
    /// the list's empty-space menu); nil keeps AppKit's.
    var menuProvider: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?() ?? super.menu(for: event)
    }

    /// Told `true` while a right-click menu this button opened is open, `false` once it closes
    /// (the sidebar keeps its hover-revealed + shown meanwhile).
    var onMenuOpenChange: ((Bool) -> Void)?

    /// The button stays pressed (lit) while its own menu is open, after the pointer leaves it.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        changeHover { $0.pressed = true }
        onMenuOpenChange?(true)
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        changeHover { $0.pressed = false }
        onMenuOpenChange?(false)
    }

    /// Makes the icon image for the current point size, once the button shows: a hidden button, or one in a
    /// hidden row, has none yet (REOPEN-F7: each workspace row's 5 hover-only buttons made theirs before the
    /// window's first frame, about 4 ms of it). Showing, joining a window, a layout and a size read make it.
    private func renderIcon() {
        guard !isHiddenOrHasHiddenAncestor else { return }
        let size = pointSize()
        guard size != renderedSize else { return }
        renderedSize = size
        let side = CGFloat.iconRowSize(forLabelPointSize: size)
        let image = symbol.map { NSImage.icon(symbol: $0, size: side) } ?? NSImage.icon(icon, size: side)
        image.accessibilityDescription = label
        self.image = image
    }

    /// The label as the themed tooltip (when ``showsLabelToolTip``). Its text, its shortcut and VoiceOver's help are set
    /// at once; the hover tracking area waits until the button shows (``NSView/defersThemedToolTipTracking``): a hidden
    /// button cannot be hovered (REOPEN-F7: each row's hidden hover buttons added theirs before the first frame).
    private func applyToolTip() {
        let text = showsLabelToolTip && !label.isEmpty ? label : nil
        if themedToolTip != text { themedToolTip = text }
    }

    override func layout() {
        super.layout()
        renderIcon()
    }

    /// Sized by its icon, as an image-only button is. `renderedSize` (0: no icon yet), not `image`: AppKit answers a
    /// button with no image of its own with a shared 1 x 1 placeholder, so `image` is never nil here.
    override var intrinsicContentSize: NSSize {
        if renderedSize == 0 { renderIcon() }
        return super.intrinsicContentSize
    }

    nonisolated override var wantsUpdateLayer: Bool { true }

    override var acceptsFirstResponder: Bool {
        guard takesKeyFocus else { return super.acceptsFirstResponder }
        return NSApp.isFullKeyboardAccessEnabled && isEnabled && !(NSApp.currentEvent.map { Self.mouseEvents.contains($0.type) } ?? false)
    }
    override var canBecomeKeyView: Bool { takesKeyFocus ? acceptsFirstResponder && !isHiddenOrHasHiddenAncestor : super.canBecomeKeyView }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { isKeyFocused = true }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { isKeyFocused = false }
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            renderIcon()
            themedToolTipCanShow()
        }
        if takesKeyFocus { keyRepaint.track() }
    }

    override func updateLayer() {
        layer?.cornerRadius = Metrics.itemCornerRadius
        performWithTheme {
            contentTintColor = tintOverride ?? (hover.state.hovering || hover.state.pressed ? Palette.textPrimary : Palette.textSecondary)
        }
        // The theme's focus ring through the shared chrome (ChromeHover), only in the key window.
        let ring = takesKeyFocus && KeyWindowRepaint.showsFocus(self, focused: isKeyFocused)
        if hover.state.focused != ring { hover.state.focused = ring }
        hover.refresh(animated: false)
    }

    private func changeHover(_ change: (inout ChromeHover.State) -> Void) {
        change(&hover.state)
        needsDisplay = true
    }

    /// A middle press is the row's, never the button's: it goes up the responder chain to the sidebar list, so a
    /// middle-click on a hovered row's ✕ closes that row as anywhere else on it does (`SidebarMiddleClick`).
    override func otherMouseDown(with event: NSEvent) { nextResponder?.otherMouseDown(with: event) }
    override func otherMouseUp(with event: NSEvent) { nextResponder?.otherMouseUp(with: event) }

    /// A pointer press before this moment (`NSEvent.timestamp`, seconds since boot) is ignored: the
    /// button just showed under the pointer (``ignorePointer(for:now:)``). Keys and VoiceOver are
    /// never ignored. A stored deadline, no timer, as ``SidebarUpdateButton`` keeps it.
    private var ignoresPointerUntil: TimeInterval = 0

    /// Ignores pointer presses for `duration` from now: the button just showed where the pointer
    /// may already be clicking, so a click meant for what was there must not land on this.
    func ignorePointer(for duration: TimeInterval = SidebarUpdateButton.appearGuard,
                       now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        ignoresPointerUntil = now + duration
    }

    /// Whether a pointer press at `timestamp` (an `NSEvent.timestamp`) is ignored.
    func ignoresPointer(at timestamp: TimeInterval) -> Bool { timestamp < ignoresPointerUntil }

    /// NSButton tracks the click inside `super.mouseDown` and returns on release.
    override func mouseDown(with event: NSEvent) {
        if ignoresPointer(at: event.timestamp) { return }
        guard isEnabled else { return super.mouseDown(with: event) }
        changeHover { $0.pressed = true }
        super.mouseDown(with: event)
        changeHover { $0.pressed = false }
    }

    /// A button hidden under the pointer (the header + while the sidebar
    /// is not hovered) gets no exit event; the hover owner clears it, and it
    /// reappears with the hover the pointer gives it then.
    override func viewDidHide() {
        super.viewDidHide()
        changeHover { $0.pressed = false }
        hover.pointer?.refresh()
    }

    /// A move into a shown superview in the same window shows the button with no unhide or window change.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard window != nil else { return }
        renderIcon()
        themedToolTipCanShow()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        renderIcon()
        themedToolTipCanShow()
        hover.pointer?.refresh()
    }
}
