import AppKit

/// A native contextual control that the outline's display host can hit-test.
@MainActor
public final class CloudVPNHelpButton: NSButton {
    var openSetup: (() -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .inline
        contentTintColor = .secondaryLabelColor
        target = self
        action = #selector(showSetup)
        toolTip = CloudPortsStatusPresentation.routeNote
        setAccessibilityIdentifier("CloudPortsVPNHelpButton")
        setAccessibilityLabel(String(localized: "cloudTree.ports.setupVPN", defaultValue: "Set Up VPN…"))
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override var acceptsFirstResponder: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }

    @objc private func showSetup() { openSetup?() }
}
