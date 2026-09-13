import AppKit

/// One native activation path for the Ports callout and compact help affordance.
@MainActor
final class CloudVPNSetupButton: NSButton {
    enum Presentation {
        case text
        case helpIcon
    }

    var setup: @MainActor (NSWindow?) -> Void = { _ in }

    override var acceptsFirstResponder: Bool { isEnabled }

    init(frame frameRect: NSRect, presentation: Presentation) {
        super.init(frame: frameRect)
        let warning = CloudPortsVPNWarning()
        controlSize = .small
        setButtonType(.momentaryPushIn)
        toolTip = warning.help
        setAccessibilityLabel(warning.setupTitle)
        setAccessibilityHelp(warning.help)
        switch presentation {
        case .text:
            title = warning.setupTitle
            bezelStyle = .rounded
            setAccessibilityIdentifier("CloudPortsVPNEmptyStateSetupButton")
        case .helpIcon:
            title = ""
            image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
            imagePosition = .imageOnly
            bezelStyle = .inline
            contentTintColor = .secondaryLabelColor
            setAccessibilityIdentifier("CloudPortsVPNWarningButton")
        }
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
}
