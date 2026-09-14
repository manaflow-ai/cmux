import AppKit
import CmuxAppKitSupportUI
import SwiftUI

/// Installs the failure card in the window's native overlay layer.
///
/// Cloud terminal views are AppKit portal views. A SwiftUI overlay mounted in
/// the workspace content can render behind the terminal and let terminal text
/// show through the error. The bridge keeps a native card above the portal
/// host while keeping all points outside the card untouched.
struct CloudPaneCreationFailurePresentation: ViewModifier {
    let failureStore: CloudPaneCreationFailureStore

    func body(content: Content) -> some View {
        content.background(
            CloudPaneCreationFailureWindowBridge(
                failure: failureStore.failure,
                onDismiss: { [weak failureStore] id in failureStore?.dismiss(id: id) }
            )
        )
    }
}

@MainActor
private struct CloudPaneCreationFailureWindowBridge: NSViewRepresentable {
    let failure: CloudPaneCreationFailure?
    let onDismiss: (UUID) -> Void

    func makeNSView(context: Context) -> CloudPaneCreationFailureOverlayHostView {
        let view = CloudPaneCreationFailureOverlayHostView(frame: .zero)
        view.update(failure: failure, onDismiss: onDismiss)
        return view
    }

    func updateNSView(_ nsView: CloudPaneCreationFailureOverlayHostView, context: Context) {
        nsView.update(failure: failure, onDismiss: onDismiss)
    }

    static func dismantleNSView(_ nsView: CloudPaneCreationFailureOverlayHostView, coordinator: ()) {
        nsView.detach()
    }
}

/// Owns a card that is inserted above the window's portal views.
@MainActor
final class CloudPaneCreationFailureOverlayHostView: NSView {
    private let card = CloudPaneCreationFailureOverlayView(frame: .zero)
    private let chromeComposition = AppWindowChromeComposition()
    private var installConstraints: [NSLayoutConstraint] = []
    private weak var installedContainer: NSView?
    private weak var installedReference: NSView?
    private var pendingFailure: CloudPaneCreationFailure?
    private var pendingDismiss: ((UUID) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(failure: CloudPaneCreationFailure?, onDismiss: @escaping (UUID) -> Void) {
        pendingFailure = failure
        pendingDismiss = onDismiss
        guard let failure else {
            card.removeFromSuperview()
            NSLayoutConstraint.deactivate(installConstraints)
            installConstraints.removeAll()
            isHidden = true
            return
        }
        card.update(failure: failure, onDismiss: onDismiss)
        isHidden = false
        _ = ensureInstalled()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        _ = ensureInstalled()
    }

    func detach() {
        card.removeFromSuperview()
        NSLayoutConstraint.deactivate(installConstraints)
        installConstraints.removeAll()
    }

    @discardableResult
    private func ensureInstalled() -> Bool {
        guard pendingFailure != nil,
              let window,
              let target = chromeComposition.contentOverlayTargetResolver.installationTarget(for: window) else { return false }
        if card.superview !== target.container || installedContainer !== target.container || installedReference !== target.reference {
            NSLayoutConstraint.deactivate(installConstraints)
            installConstraints.removeAll()
            card.removeFromSuperview()
            target.container.addSubview(card, positioned: .above, relativeTo: nil)
            installConstraints = [
                card.centerXAnchor.constraint(equalTo: target.reference.centerXAnchor),
                card.centerYAnchor.constraint(equalTo: target.reference.centerYAnchor),
            ]
            NSLayoutConstraint.activate(installConstraints)
            installedContainer = target.container
            installedReference = target.reference
        }
        return true
    }
}

/// A native, opaque failure card above portal-hosted terminal views.
@MainActor
final class CloudPaneCreationFailureOverlayView: NSView {
    private let iconView = NSImageView(frame: .zero)
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let recoveryLabel = NSTextField(wrappingLabelWithString: "")
    private let dismissButton = NSButton(frame: .zero)
    private var currentFailure: CloudPaneCreationFailure?
    private var onDismiss: ((UUID) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.38).cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.98).cgColor
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.22).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        iconView.contentTintColor = .systemOrange
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 19, weight: .semibold)

        for label in [titleLabel, detailLabel, recoveryLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.maximumNumberOfLines = 4
            label.lineBreakMode = .byWordWrapping
        }
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        detailLabel.font = .systemFont(ofSize: 12, weight: .medium)
        detailLabel.textColor = .secondaryLabelColor
        recoveryLabel.font = .systemFont(ofSize: 11)
        recoveryLabel.textColor = .secondaryLabelColor

        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.title = String(localized: "cloudPane.newTerminalFailed.ok", defaultValue: "OK")
        dismissButton.bezelStyle = .rounded
        dismissButton.controlSize = .regular
        dismissButton.target = self
        dismissButton.action = #selector(handleDismiss)
        dismissButton.setAccessibilityIdentifier("CloudPaneCreationFailureDismiss")

        let labels = NSStackView(views: [titleLabel, detailLabel, recoveryLabel])
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 6
        addSubview(iconView)
        addSubview(labels)
        addSubview(dismissButton)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            labels.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            labels.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            labels.bottomAnchor.constraint(equalTo: dismissButton.topAnchor, constant: -14),
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            dismissButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
        setAccessibilityIdentifier("CloudPaneCreationFailure")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(failure: CloudPaneCreationFailure, onDismiss: @escaping (UUID) -> Void) {
        currentFailure = failure
        self.onDismiss = onDismiss
        titleLabel.stringValue = failure.title
        detailLabel.stringValue = failure.errorText
        recoveryLabel.stringValue = failure.recoveryText
        needsLayout = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        currentFailure.map { CloudErrorCopy.menu($0.copyableText) }
    }

    @objc private func handleDismiss() {
        guard let id = currentFailure?.id else { return }
        onDismiss?(id)
    }
}
