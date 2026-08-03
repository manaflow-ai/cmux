import AppKit

@MainActor
final class BrowserDesignModeToolbarButtonView: NSButton {
    private var controller: BrowserDesignModeController?
    private var iconPointSize: CGFloat = 12
    private var hitSize: CGFloat = 24
    private var inactiveColor = NSColor.secondaryLabelColor
    private var onToggle: (@MainActor () async -> Bool)?
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        imagePosition = .imageOnly
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 6
        target = self
        action = #selector(toggleDesignMode)
        setAccessibilityIdentifier("BrowserDesignModeButton")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: hitSize, height: hitSize)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateBackground()
    }

    func update(
        controller: BrowserDesignModeController,
        iconPointSize: CGFloat,
        hitSize: CGFloat,
        inactiveColor: NSColor,
        onToggle: @escaping @MainActor () async -> Bool
    ) {
        self.controller = controller
        self.iconPointSize = iconPointSize
        self.hitSize = hitSize
        self.inactiveColor = inactiveColor
        self.onToggle = onToggle
        invalidateIntrinsicContentSize()
        render()
    }

    @objc private func toggleDesignMode() {
        guard let onToggle else { return }
        Task { @MainActor [weak self] in
            guard await onToggle() else { return }
            self?.render()
        }
    }

    private func render() {
        guard let controller else { return }
        image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: controller.isActive ? "paintbrush.pointed.fill" : "paintbrush.pointed",
            pointSize: iconPointSize,
            weight: .medium
        )
        contentTintColor = controller.isActive ? .controlAccentColor : inactiveColor
        isEnabled = controller.canToggle
        alphaValue = controller.canToggle ? 1 : 0.4
        let help = controller.unavailableMessage ?? String(
            format: String(
                localized: "browser.designMode.buttonHelpFormat",
                defaultValue: "Design Mode (%@)"
            ),
            KeyboardShortcutSettings.shortcut(for: .toggleBrowserDesignMode).displayString
        )
        toolTip = help
        setAccessibilityLabel(help)
        updateBackground()
    }

    private func updateBackground() {
        layer?.backgroundColor = isHovered && isEnabled
            ? NSColor.labelColor.withAlphaComponent(0.08).cgColor
            : NSColor.clear.cgColor
    }
}
