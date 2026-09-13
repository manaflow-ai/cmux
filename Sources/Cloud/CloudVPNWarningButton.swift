import AppKit

/// Standard help affordance: hover explains optional VPN access; activation opens setup.
@MainActor
final class CloudVPNWarningButton: NSButton {
    var setup: @MainActor (NSWindow?) -> Void = { _ in }

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let warning = CloudPortsVPNWarning()
        title = ""
        image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        imagePosition = .imageOnly
        bezelStyle = .inline
        controlSize = .small
        contentTintColor = .secondaryLabelColor
        setButtonType(.momentaryPushIn)
        toolTip = warning.help
        setAccessibilityLabel(warning.setupTitle)
        setAccessibilityHelp(warning.help)
        setAccessibilityIdentifier("CloudPortsVPNWarningButton")
        target = self
        action = #selector(openSetup)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func openSetup() {
        setup(window)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if [UInt16(36), 76, 49].contains(event.keyCode) {
            performClick(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}
