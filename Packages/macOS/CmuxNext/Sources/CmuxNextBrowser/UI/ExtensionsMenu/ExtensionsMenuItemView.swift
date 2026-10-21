import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// One extension in the Extensions bubble, Chrome's legacy `ExtensionMenuItemView` with Edge's
/// second line: the primary button (the extension's icon, its name and, under it, its access on
/// the current site; a click runs the extension's action), then a side panel button when the
/// extension has a side panel, the pin toggle, and the "more options" button with the extension's
/// context menu. The row highlights as a whole under the pointer; its trailing buttons have their
/// own highlight on top. A pinned extension's pin sits on the theme's accent.
final class ExtensionsMenuItemView: NSView {
    let extensionID: String
    let primary: ExtensionsMenuHoverButton
    let sidePanelButton: ExtensionsMenuHoverButton
    let pinButton: ExtensionsMenuHoverButton
    let moreButton: ExtensionsMenuHoverButton
    private(set) var info: BrowserExtensionInfo
    private(set) var access: ExtensionSiteAccess
    private(set) var isPinned: Bool
    private(set) var canPin: Bool
    private(set) var hasSidePanel: Bool
    private let style: ExtensionsMenuStyle
    private var tracking: NSTrackingArea?
    private var isRowHovered = false { didSet { if oldValue != isRowHovered { needsDisplay = true } } }

    var onRun: (() -> Void)?
    var onSidePanel: (() -> Void)?
    var onPin: ((Bool) -> Void)?
    var onMore: (() -> Void)?

    init(info: BrowserExtensionInfo, icon: NSImage?, access: ExtensionSiteAccess, canPin: Bool, hasSidePanel: Bool,
         style: ExtensionsMenuStyle = .standard) {
        extensionID = info.id
        self.info = info
        self.access = access
        isPinned = info.isPinned
        self.canPin = canPin
        self.hasSidePanel = hasSidePanel
        self.style = style
        primary = ExtensionsMenuHoverButton(
            image: icon, imageSize: style.extensionIcon, imageBox: style.extensionIconBox, title: info.name, detail: true,
            insets: NSEdgeInsets(top: 0, left: style.rowInset, bottom: 0, right: style.rowInset),
            style: style, tint: nil
        )
        let square = (style.squareButton - style.buttonIcon) / 2
        let insets = NSEdgeInsets(top: square, left: square, bottom: square, right: square)
        sidePanelButton = ExtensionsMenuHoverButton(image: NSImage.icon(.browserExtensionsSidepanel, size: style.buttonIcon),
                                                    imageSize: style.buttonIcon, imageBox: style.buttonIcon, insets: insets, style: style)
        pinButton = ExtensionsMenuHoverButton(image: NSImage.icon(.browserToolbarPin, size: style.buttonIcon),
                                              imageSize: style.buttonIcon, imageBox: style.buttonIcon, insets: insets, style: style)
        moreButton = ExtensionsMenuHoverButton(image: NSImage.icon(.browserToolbarMore, size: style.buttonIcon),
                                               imageSize: style.buttonIcon, imageBox: style.buttonIcon, insets: insets, style: style)
        super.init(frame: NSRect(x: 0, y: 0, width: style.width - style.padding * 2, height: style.rowHeight))
        for view in [primary, sidePanelButton, pinButton, moreButton] { addSubview(view) }
        primary.drawsHighlight = false
        primary.onHighlightChange = { [weak self] in self?.needsDisplay = true }
        primary.onPress = { [weak self] in self?.onRun?() }
        sidePanelButton.onPress = { [weak self] in self?.onSidePanel?() }
        sidePanelButton.themedToolTip = Strings.extensionMenuSidePanelTooltip
        pinButton.onPress = { [weak self] in self?.togglePin() }
        moreButton.onPress = { [weak self] in self?.onMore?() }
        moreButton.themedToolTip = Strings.extensionMenuMoreTooltip
        setAccessibilityElement(false)
        apply(info, icon: icon, access: access, canPin: canPin, hasSidePanel: hasSidePanel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Takes a new state of the same extension (a rename, a pin elsewhere, a new icon, another
    /// site) without rebuilding the row.
    func apply(_ info: BrowserExtensionInfo, icon: NSImage?, access: ExtensionSiteAccess, canPin: Bool, hasSidePanel: Bool) {
        self.info = info
        self.access = access
        self.canPin = canPin
        self.hasSidePanel = hasSidePanel
        primary.titleLabel.stringValue = info.name
        let detail = Strings.extensionAccess(access)
        primary.detailLabel.stringValue = detail
        primary.detailLabel.isHidden = detail.isEmpty
        primary.needsLayout = true
        primary.setImage(icon, size: style.extensionIcon)
        primary.setAccessibilityLabel(info.name)
        primary.setAccessibilityHelp(detail.isEmpty ? nil : detail)
        primary.setAccessibilityIdentifier(ExtensionsMenu.rowIdentifier(info.id))
        primary.isEnabled = info.isEnabled
        sidePanelButton.setAccessibilityIdentifier(ExtensionsMenu.sidePanelIdentifier(info.id))
        sidePanelButton.setAccessibilityLabel(String(format: Strings.extensionMenuSidePanelAccessible, info.name))
        pinButton.setAccessibilityIdentifier(ExtensionsMenu.pinIdentifier(info.id))
        moreButton.setAccessibilityIdentifier(ExtensionsMenu.moreIdentifier(info.id))
        // Chrome names the more button after the extension; cmux says what it does too.
        moreButton.setAccessibilityLabel(String(format: Strings.extensionMoreFormat, info.name))
        sidePanelButton.isHidden = !hasSidePanel
        pinButton.isHidden = !canPin
        setPinned(info.isPinned)
        needsLayout = true
    }

    /// Shows the pin state as a toggle: pinned is the pin on the theme's accent, unpinned the
    /// pin in the secondary ink, with "Pin" / "Unpin" tooltips and "Pin {name}" / "Unpin {name}"
    /// names.
    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        pinButton.isSelected = pinned
        pinButton.themedToolTip = pinned ? Strings.extensionMenuUnpinTooltip : Strings.extensionMenuPinTooltip
        pinButton.setAccessibilityLabel(String(format: pinned ? Strings.extensionMenuUnpinAccessible : Strings.extensionMenuPinAccessible,
                                               info.name))
        pinButton.setAccessibilityValue(pinned ? 1 : 0)
    }

    /// The pin button: flips the state at once (the store confirms it), announces it as Chrome
    /// does, and keeps the bubble open.
    func togglePin() {
        let pinned = !isPinned
        setPinned(pinned)
        NSAccessibility.post(element: pinButton, notification: .announcementRequested, userInfo: [
            .announcement: pinned ? Strings.extensionMenuPinnedAnnouncement : Strings.extensionMenuUnpinnedAnnouncement,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        onPin?(pinned)
    }

    /// The keyboard order of the row: primary, side panel and pin (when shown), more.
    var focusableButtons: [ExtensionsMenuHoverButton] {
        [primary] + (hasSidePanel ? [sidePanelButton] : []) + (canPin ? [pinButton] : []) + [moreButton]
    }

    override func layout() {
        super.layout()
        let square = style.squareButton
        let y = (bounds.height - square) / 2
        var trailing = bounds.width - (style.rowInset - (square - style.buttonIcon) / 2)
        for button in [moreButton, pinButton, sidePanelButton] where !button.isHidden {
            trailing -= square
            button.frame = NSRect(x: trailing, y: y, width: square, height: square)
            trailing -= style.buttonSpacing
        }
        primary.frame = NSRect(x: 0, y: 0, width: max(0, trailing), height: bounds.height)
    }

    // MARK: Highlight

    /// The row's highlight: under the pointer anywhere in the row, or while its primary button
    /// has the keyboard focus or a press.
    override func draw(_ dirtyRect: NSRect) {
        guard primary.isEnabled, isRowHovered || primary.isHighlighted else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: style.highlightRadius, yRadius: style.highlightRadius)
        performWithTheme {
            (primary.isPressed ? Palette.pressedFill : Palette.hoverFill).setFill()
            path.fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isRowHovered = true }
    override func mouseExited(with event: NSEvent) { isRowHovered = false }

    /// Reads the hover again from the pointer (a menu shown from the row tracked the mouse).
    func refreshHover() {
        guard let window else { return }
        isRowHovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
}
