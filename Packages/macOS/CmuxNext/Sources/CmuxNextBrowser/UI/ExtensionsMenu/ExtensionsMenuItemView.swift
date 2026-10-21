import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// One extension in the Extensions bubble, Chrome's legacy `ExtensionMenuItemView`: the primary
/// button (the extension's icon in a 28-point box and its name; a click runs the extension's
/// action), the pin button, and the "more options" button with the extension's context menu.
/// Each is its own hover button with its own highlight, as in Chrome.
final class ExtensionsMenuItemView: NSView {
    let extensionID: String
    let primary: ExtensionsMenuHoverButton
    let pinButton: ExtensionsMenuHoverButton
    let moreButton: ExtensionsMenuHoverButton
    private(set) var info: BrowserExtensionInfo
    private(set) var isPinned: Bool
    private(set) var canPin: Bool
    private let style: ExtensionsMenuStyle

    var onRun: (() -> Void)?
    var onPin: ((Bool) -> Void)?
    var onMore: (() -> Void)?

    init(info: BrowserExtensionInfo, icon: NSImage?, canPin: Bool, style: ExtensionsMenuStyle = .chrome) {
        extensionID = info.id
        self.info = info
        isPinned = info.isPinned
        self.canPin = canPin
        self.style = style
        primary = ExtensionsMenuHoverButton(
            image: icon, imageSize: style.extensionIcon, imageBox: style.extensionIconBox, title: info.name,
            insets: NSEdgeInsets(top: style.primaryVerticalInset, left: 0, bottom: style.primaryVerticalInset, right: 0),
            style: style, tint: nil
        )
        let square = NSEdgeInsets(top: style.buttonMargin, left: style.buttonMargin, bottom: style.buttonMargin, right: style.buttonMargin)
        pinButton = ExtensionsMenuHoverButton(image: nil, imageSize: style.buttonIcon, imageBox: style.buttonIcon, insets: square, style: style)
        moreButton = ExtensionsMenuHoverButton(image: NSImage.icon(.browserToolbarMore, size: style.buttonIcon),
                                               imageSize: style.buttonIcon, imageBox: style.buttonIcon, insets: square, style: style)
        super.init(frame: NSRect(x: 0, y: 0, width: style.width - style.dialogInset * 2, height: style.rowHeight))
        for view in [primary, pinButton, moreButton] { addSubview(view) }
        primary.onPress = { [weak self] in self?.onRun?() }
        pinButton.onPress = { [weak self] in self?.togglePin() }
        moreButton.onPress = { [weak self] in self?.onMore?() }
        moreButton.themedToolTip = Strings.extensionMenuMoreTooltip
        setAccessibilityElement(false)
        apply(info, icon: icon, canPin: canPin)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Takes a new state of the same extension (a rename, a pin elsewhere, a new icon) without
    /// rebuilding the row.
    func apply(_ info: BrowserExtensionInfo, icon: NSImage?, canPin: Bool) {
        self.info = info
        self.canPin = canPin
        primary.titleLabel.stringValue = info.name
        primary.setImage(icon, size: style.extensionIcon)
        primary.setAccessibilityLabel(info.name)
        primary.setAccessibilityIdentifier(ExtensionsMenu.rowIdentifier(info.id))
        primary.isEnabled = info.isEnabled
        pinButton.setAccessibilityIdentifier(ExtensionsMenu.pinIdentifier(info.id))
        moreButton.setAccessibilityIdentifier(ExtensionsMenu.moreIdentifier(info.id))
        // Chrome names the more button after the extension; cmux says what it does too.
        moreButton.setAccessibilityLabel(String(format: Strings.extensionMoreFormat, info.name))
        pinButton.isHidden = !canPin
        setPinned(info.isPinned)
        needsLayout = true
    }

    /// Shows the pin state: Chrome's keep icon to pin, its keep-off icon (in the strong ink) to
    /// unpin, with "Pin" / "Unpin" tooltips and "Pin {name}" / "Unpin {name}" names.
    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        pinButton.setImage(NSImage.icon(pinned ? .browserToolbarUnpin : .browserToolbarPin, size: style.buttonIcon),
                           size: style.buttonIcon)
        pinButton.imageView.themeTint = pinned ? { Palette.textPrimary } : { Palette.textSecondary }
        pinButton.themedToolTip = pinned ? Strings.extensionMenuUnpinTooltip : Strings.extensionMenuPinTooltip
        pinButton.setAccessibilityLabel(String(format: pinned ? Strings.extensionMenuUnpinAccessible : Strings.extensionMenuPinAccessible,
                                               info.name))
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

    /// The keyboard order of the row: primary, pin (when shown), more.
    var focusableButtons: [ExtensionsMenuHoverButton] { [primary] + (canPin ? [pinButton] : []) + [moreButton] }

    override func layout() {
        super.layout()
        let square = style.squareButton
        var trailing = bounds.width
        trailing -= square
        moreButton.frame = NSRect(x: trailing, y: (bounds.height - square) / 2, width: square, height: square)
        if canPin {
            trailing -= square
            pinButton.frame = NSRect(x: trailing, y: (bounds.height - square) / 2, width: square, height: square)
        }
        primary.frame = NSRect(x: 0, y: 0, width: max(0, trailing), height: bounds.height)
    }
}
