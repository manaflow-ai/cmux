import AppKit

/// Native reconnect card shared by the terminal portal and its representable anchor.
@MainActor
final class CloudTerminalReconnectOverlayView: NSView {
    var onReconnect: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let cardView = NSVisualEffectView(frame: .zero)
    private let iconView = NSImageView(frame: .zero)
    private let spinner = NSProgressIndicator(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let reconnectButton = NSButton(frame: .zero)
    private let dismissButton = NSButton(frame: .zero)
    private(set) var currentPresentation: CloudTerminalReconnectOverlayPolicy.Presentation?

    /// Creates a card whose controls are localized and hit-testable by AppKit.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        autoresizingMask = [.width, .height]

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.material = .hudWindow
        cardView.blendingMode = .withinWindow
        cardView.state = .active
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 12
        cardView.layer?.masksToBounds = true
        cardView.layer?.borderWidth = 1
        cardView.layer?.borderColor = NSColor.white.withAlphaComponent(0.11).cgColor
        addSubview(cardView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        iconView.contentTintColor = NSColor.secondaryLabelColor

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.alignment = .center
        detailLabel.font = .systemFont(ofSize: 12, weight: .medium)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 3

        reconnectButton.translatesAutoresizingMaskIntoConstraints = false
        reconnectButton.title = String(localized: "cloud.overlay.reconnect.button", defaultValue: "Reconnect")
        reconnectButton.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: nil
        )
        reconnectButton.imagePosition = .imageLeading
        reconnectButton.bezelStyle = .rounded
        reconnectButton.controlSize = .regular
        reconnectButton.target = self
        reconnectButton.action = #selector(handleReconnect)

        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: String(localized: "common.close", defaultValue: "Close")
        )
        dismissButton.bezelStyle = .texturedRounded
        dismissButton.isBordered = false
        dismissButton.controlSize = .small
        dismissButton.toolTip = String(localized: "common.close", defaultValue: "Close")
        dismissButton.setAccessibilityLabel(String(localized: "common.close", defaultValue: "Close"))
        dismissButton.target = self
        dismissButton.action = #selector(handleDismiss)

        let stack = NSStackView(views: [iconView, spinner, titleLabel, detailLabel, reconnectButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        cardView.addSubview(stack)
        cardView.addSubview(dismissButton)

        NSLayoutConstraint.activate([
            cardView.centerXAnchor.constraint(equalTo: centerXAnchor),
            cardView.centerYAnchor.constraint(equalTo: centerYAnchor),
            cardView.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            cardView.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            stack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -22),
            stack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -24),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
            spinner.widthAnchor.constraint(equalToConstant: 24),
            spinner.heightAnchor.constraint(equalToConstant: 24),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
            dismissButton.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 7),
            dismissButton.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -7),
            dismissButton.widthAnchor.constraint(equalToConstant: 22),
            dismissButton.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Routes hits to the two controls while keeping the rest of the card passive.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        if let dismissHit = dismissButton.hitTest(convert(point, to: dismissButton)) {
            return dismissHit
        }
        if let buttonHit = reconnectButton.hitTest(convert(point, to: reconnectButton)) {
            return buttonHit
        }
        if cardView.frame.contains(point) {
            return self
        }
        return nil
    }

    /// Invokes the selected action when AppKit delivers a card click.
    override func mouseDown(with event: NSEvent) {
        let pointInButton = reconnectButton.convert(event.locationInWindow, from: nil)
        let pointInDismiss = dismissButton.convert(event.locationInWindow, from: nil)
        if !dismissButton.isHidden,
           dismissButton.bounds.contains(pointInDismiss) {
            onDismiss?()
            return
        }
        if reconnectButton.isHidden == false,
           reconnectButton.bounds.contains(pointInButton) {
            onReconnect?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        currentPresentation.map { CloudErrorCopy.menu($0.copyableError) }
    }

    /// Applies a new connection snapshot without rebuilding unchanged labels.
    ///
    /// - Parameter presentation: The title, detail, and available actions to show.
    func apply(_ presentation: CloudTerminalReconnectOverlayPolicy.Presentation) {
        guard currentPresentation != presentation else { return }
        currentPresentation = presentation
        titleLabel.stringValue = presentation.title
        detailLabel.stringValue = presentation.detail
        reconnectButton.menu = CloudErrorCopy.menu(presentation.copyableError)
        reconnectButton.isHidden = !presentation.showsReconnectButton
        spinner.isHidden = !presentation.showsProgress
        iconView.isHidden = presentation.showsProgress
        if presentation.showsProgress {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        iconView.image = NSImage(
            systemSymbolName: presentation.showsReconnectButton ? "wifi.exclamationmark" : "arrow.triangle.2.circlepath",
            accessibilityDescription: nil
        )
    }

    @objc private func handleReconnect() {
        onReconnect?()
    }

    @objc private func handleDismiss() {
        onDismiss?()
    }
}
