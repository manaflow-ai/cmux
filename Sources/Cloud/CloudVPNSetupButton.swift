import AppKit

/// One native activation path for the Ports callout and compact help affordance.
@MainActor
final class CloudVPNSetupButton: NSButton {
    enum Presentation {
        case text
        case helpIcon
    }

    var setup: @MainActor (NSWindow?) -> Void = { _ in }

    private let presentation: Presentation
    private var trackingArea: NSTrackingArea?
    private var isPointerInside = false {
        didSet { updateHelpHighlight() }
    }

    override var acceptsFirstResponder: Bool { isEnabled }

    init(frame frameRect: NSRect, presentation: Presentation) {
        self.presentation = presentation
        super.init(frame: frameRect)
        let warning = CloudPortsVPNWarning()
        controlSize = .small
        setButtonType(.momentaryPushIn)
        setAccessibilityRole(.button)
        toolTip = warning.help
        setAccessibilityLabel(warning.setupTitle)
        setAccessibilityHelp(warning.help)
        switch presentation {
        case .text:
            title = warning.setupTitle
            bezelStyle = .inline
            isBordered = false
            contentTintColor = .controlAccentColor
            setAccessibilityIdentifier("CloudPortsVPNEmptyStateSetupButton")
        case .helpIcon:
            title = ""
            image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
            imagePosition = .imageOnly
            bezelStyle = .inline
            isBordered = false
            contentTintColor = .secondaryLabelColor
            setAccessibilityIdentifier("CloudPortsVPNWarningButton")
        }
        focusRingType = .default
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.masksToBounds = false
        updateHelpHighlight()
        target = self
        action = #selector(openSetup)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func openSetup() {
        guard isEnabled else { return }
        setup(window)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if isEnabled && [UInt16(36), 76, 49].contains(event.keyCode) {
            performClick(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder { updateHelpHighlight() }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { updateHelpHighlight() }
        return resigned
    }

    override var isHighlighted: Bool {
        didSet { updateHelpHighlight() }
    }

    private func updateHelpHighlight() {
        guard presentation == .helpIcon else { return }
        let isFocused = window?.firstResponder === self
        let shouldHighlight = isPointerInside || isHighlighted || isFocused
        layer?.backgroundColor = shouldHighlight
            ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            : NSColor.clear.cgColor
    }

}
