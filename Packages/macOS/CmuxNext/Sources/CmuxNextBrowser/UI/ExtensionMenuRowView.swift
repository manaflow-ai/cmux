import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// One Extensions menu row, on the shared popup row (``PopupRowView``): icon and name (click runs
/// the action), a pin toggle and a "more" button. Gray hover fill, no accent.
final class ExtensionMenuRowView: PopupRowView {
    let extensionID: String
    var onRun: (() -> Void)?
    var onPin: (() -> Void)?
    var onMore: (() -> Void)?

    private(set) var isPinned: Bool
    private let pinButton: NSButton
    private let moreButton: NSButton

    init(info: BrowserExtensionInfo, icon: NSImage?, canPin: Bool) {
        extensionID = info.id
        isPinned = info.isPinned
        let pinButton = NSButton(image: NSImage(), target: nil, action: nil)
        let moreButton = NSButton(image: NSImage.icon(.browserToolbarMore, size: 16), target: nil, action: nil)
        self.pinButton = pinButton
        self.moreButton = moreButton
        let iconView = NSImageView(image: icon ?? NSImage())
        iconView.imageScaling = .scaleProportionallyDown
        iconView.alphaValue = info.isEnabled ? 1 : 0.45
        let buttons = NSStackView(views: [pinButton, moreButton])
        buttons.spacing = 2
        var layout = Layout()
        layout.leading = 14
        layout.leadingColumn = 16
        layout.gap = 8
        layout.trailing = 10
        layout.trailingGap = 6
        layout.fillInset = NSSize(width: 5, height: 1)
        super.init(leading: iconView, title: info.name, trailing: buttons, layout: layout)
        frame = NSRect(x: 0, y: 0, width: 280, height: layout.minHeight)
        translatesAutoresizingMaskIntoConstraints = true
        // A system menu: the system menu font and label colors.
        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.themeColor = { info.isEnabled ? .labelColor : .secondaryLabelColor }
        setAccessibilityIdentifier(ExtensionsMenu.rowIdentifier(info.id))
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(info.name)
        onActivate = { [weak self] in self?.onRun?() }

        for button in [pinButton, moreButton] {
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.imagePosition = .imageOnly
            button.contentTintColor = .secondaryLabelColor
            button.target = self
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 22),
                button.heightAnchor.constraint(equalToConstant: 22),
            ])
        }
        NSLayoutConstraint.activate([iconView.widthAnchor.constraint(equalToConstant: 16), iconView.heightAnchor.constraint(equalToConstant: 16)])
        pinButton.action = #selector(pin)
        pinButton.isHidden = !canPin
        pinButton.setAccessibilityIdentifier(ExtensionsMenu.pinIdentifier(info.id))
        moreButton.action = #selector(more)
        moreButton.setAccessibilityIdentifier(ExtensionsMenu.moreIdentifier(info.id))
        moreButton.setAccessibilityLabel(String(format: Strings.extensionMoreFormat, info.name))
        updatePin()
    }

    // MARK: Actions (also driven by `debug.extensions.menu`)

    func run() { onRun?() }

    @objc func pin() {
        isPinned.toggle()
        updatePin()
        onPin?()
    }

    @objc func more() { onMore?() }

    private func updatePin() {
        pinButton.image = NSImage.icon(isPinned ? .browserToolbarUnpin : .browserToolbarPin, size: 16)
        pinButton.setAccessibilityLabel(isPinned ? Strings.extensionMenuTitle(.unpin) : Strings.extensionMenuTitle(.pin))
        pinButton.themedToolTip = pinButton.accessibilityLabel()
        pinButton.contentTintColor = isPinned ? .labelColor : .secondaryLabelColor
    }

    /// The menu's keyboard highlight draws like the pointer's.
    override var drawsHighlight: Bool { super.drawsHighlight || enclosingMenuItem?.isHighlighted == true }
}
