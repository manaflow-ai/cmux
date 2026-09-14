import AppKit
import CmuxAppKitSupportUI
import SwiftUI

/// Installs the failure card in the window's native overlay layer.
///
/// Cloud terminal views are AppKit portal views. A SwiftUI overlay mounted in
/// the workspace content can render behind the terminal and let terminal text
/// show through the error. The bridge moves one native overlay above the portal
/// host while keeping all points outside the card pass-through.
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

    func makeNSView(context: Context) -> CloudPaneCreationFailureOverlayView {
        let view = CloudPaneCreationFailureOverlayView(frame: .zero)
        view.update(failure: failure, onDismiss: onDismiss)
        return view
    }

    func updateNSView(_ nsView: CloudPaneCreationFailureOverlayView, context: Context) {
        nsView.update(failure: failure, onDismiss: onDismiss)
    }

    static func dismantleNSView(_ nsView: CloudPaneCreationFailureOverlayView, coordinator: ()) {
        nsView.removeFromSuperview()
    }
}

/// A native card above portal-hosted terminal views.
@MainActor
final class CloudPaneCreationFailureOverlayView: NSView {
    private let cardView = NSView(frame: .zero)
    private let iconView = NSImageView(frame: .zero)
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let recoveryLabel = NSTextField(wrappingLabelWithString: "")
    private let dismissButton = NSButton(frame: .zero)
    private let chromeComposition = AppWindowChromeComposition()
    private var installConstraints: [NSLayoutConstraint] = []
    private weak var installedContainer: NSView?
    private weak var installedReference: NSView?
    private var currentFailure: CloudPaneCreationFailure?
    private var onDismiss: ((UUID) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 12
        cardView.layer?.borderWidth = 1
        cardView.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.38).cgColor
        cardView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.98).cgColor
        cardView.layer?.shadowColor = NSColor.black.withAlphaComponent(0.22).cgColor
        cardView.layer?.shadowOpacity = 1
        cardView.layer?.shadowRadius = 12
        cardView.layer?.shadowOffset = CGSize(width: 0, height: -4)
        addSubview(cardView)

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
        cardView.addSubview(iconView)
        cardView.addSubview(labels)
        cardView.addSubview(dismissButton)

        NSLayoutConstraint.activate([
            cardView.centerXAnchor.constraint(equalTo: centerXAnchor),
            cardView.centerYAnchor.constraint(equalTo: centerYAnchor),
            cardView.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            cardView.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            iconView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 20),
            iconView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 22),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            labels.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            labels.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 20),
            labels.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -20),
            labels.bottomAnchor.constraint(equalTo: dismissButton.topAnchor, constant: -14),
            dismissButton.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -20),
            dismissButton.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -16),
        ])
        setAccessibilityIdentifier("CloudPaneCreationFailure")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(failure: CloudPaneCreationFailure?, onDismiss: @escaping (UUID) -> Void) {
        self.onDismiss = onDismiss
        currentFailure = failure
        guard let failure else {
            isHidden = true
            return
        }
        titleLabel.stringValue = failure.title
        detailLabel.stringValue = failure.errorText
        recoveryLabel.stringValue = failure.recoveryText
        isHidden = false
        _ = ensureInstalled()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        _ = ensureInstalled()
    }

    @discardableResult
    private func ensureInstalled() -> Bool {
        guard let window,
              let target = chromeComposition.contentOverlayTargetResolver.installationTarget(for: window) else { return false }
        if superview !== target.container || installedContainer !== target.container || installedReference !== target.reference {
            NSLayoutConstraint.deactivate(installConstraints)
            installConstraints.removeAll()
            removeFromSuperview()
            target.container.addSubview(self, positioned: .above, relativeTo: nil)
            installConstraints = [
                topAnchor.constraint(equalTo: target.reference.topAnchor),
                bottomAnchor.constraint(equalTo: target.reference.bottomAnchor),
                leadingAnchor.constraint(equalTo: target.reference.leadingAnchor),
                trailingAnchor.constraint(equalTo: target.reference.trailingAnchor),
            ]
            NSLayoutConstraint.activate(installConstraints)
            installedContainer = target.container
            installedReference = target.reference
        }
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, cardView.frame.contains(point) else { return nil }
        return super.hitTest(point)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        currentFailure.map { CloudErrorCopy.menu($0.copyableText) }
    }

    @objc private func handleDismiss() {
        guard let id = currentFailure?.id else { return }
        onDismiss?(id)
    }
}
