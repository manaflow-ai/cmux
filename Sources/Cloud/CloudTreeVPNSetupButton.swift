import AppKit

/// A native button used in the expanded Ports empty-state callout.
@MainActor
final class CloudTreeVPNSetupButton: NSButton {
    var actionHandler: (@MainActor () -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(invokeAction)
        bezelStyle = .rounded
        controlSize = .small
        setButtonType(.momentaryPushIn)
        setAccessibilityIdentifier("CloudPortsVPNEmptyStateSetupButton")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func keyDown(with event: NSEvent) {
        if [UInt16(36), 76, 49].contains(event.keyCode) { performClick(nil) }
        else { super.keyDown(with: event) }
    }

    @objc private func invokeAction() {
        actionHandler?()
    }
}
