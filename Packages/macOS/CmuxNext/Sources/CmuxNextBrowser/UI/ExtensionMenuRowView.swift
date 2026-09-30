import AppKit
import CmuxNextDesign

/// One Extensions menu row, as in Chrome: icon and name (click runs the
/// action), a pin toggle and a "more" button. Gray hover fill, no accent.
final class ExtensionMenuRowView: NSView {
    let extensionID: String
    var onRun: (() -> Void)?
    var onPin: (() -> Void)?
    var onMore: (() -> Void)?

    private(set) var isPinned: Bool
    private let pinButton: NSButton
    private let moreButton: NSButton
    private var isHovering = false { didSet { needsDisplay = true } }

    init(info: BrowserExtensionInfo, icon: NSImage?, canPin: Bool) {
        extensionID = info.id
        isPinned = info.isPinned
        pinButton = NSButton(image: NSImage(), target: nil, action: nil)
        moreButton = NSButton(image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil) ?? NSImage(),
                              target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 28))
        setAccessibilityIdentifier(ExtensionsMenu.Identifier.row(info.id))
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(info.name)

        let iconView = NSImageView(image: icon ?? NSImage())
        iconView.imageScaling = .scaleProportionallyDown
        let name = NSTextField(labelWithString: info.name)
        name.font = .menuFont(ofSize: 0)
        name.lineBreakMode = .byTruncatingTail
        name.textColor = info.isEnabled ? .labelColor : .secondaryLabelColor
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iconView.alphaValue = info.isEnabled ? 1 : 0.45

        for button in [pinButton, moreButton] {
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.imagePosition = .imageOnly
            button.contentTintColor = .secondaryLabelColor
            button.target = self
        }
        pinButton.action = #selector(pin)
        pinButton.isHidden = !canPin
        pinButton.setAccessibilityIdentifier(ExtensionsMenu.Identifier.pin(info.id))
        moreButton.action = #selector(more)
        moreButton.setAccessibilityIdentifier(ExtensionsMenu.Identifier.more(info.id))
        moreButton.setAccessibilityLabel(String(format: Strings.extensionMoreFormat, info.name))
        updatePin()

        for view in [iconView, name, pinButton, moreButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: pinButton.leadingAnchor, constant: -6),
            pinButton.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -2),
            pinButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: 22),
            pinButton.heightAnchor.constraint(equalToConstant: 22),
            moreButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            moreButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 22),
            moreButton.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Actions (also driven by `debug.extensions.menu`)

    func run() { onRun?() }

    @objc func pin() {
        isPinned.toggle()
        updatePin()
        onPin?()
    }

    @objc func more() { onMore?() }

    private func updatePin() {
        let symbol = isPinned ? "pin.fill" : "pin"
        pinButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        pinButton.setAccessibilityLabel(isPinned ? Strings.extensionMenuTitle(.unpin) : Strings.extensionMenuTitle(.pin))
        pinButton.toolTip = pinButton.accessibilityLabel()
        pinButton.contentTintColor = isPinned ? .labelColor : .secondaryLabelColor
    }

    // MARK: Mouse and drawing

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        run()
    }

    override func accessibilityPerformPress() -> Bool {
        run()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovering || enclosingMenuItem?.isHighlighted == true else { return }
        Palette.hoverFill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}
