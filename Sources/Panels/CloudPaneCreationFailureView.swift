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
    var isWorkspaceVisible = true

    func body(content: Content) -> some View {
        content.background(
            CloudPaneCreationFailureWindowBridge(
                failure: failureStore.failure,
                isWorkspaceVisible: isWorkspaceVisible,
                onRetry: failureStore.canRetry ? { [weak failureStore] id in
                    failureStore?.retry(id: id)
                } : nil,
                onDismiss: { [weak failureStore] id in failureStore?.dismiss(id: id) }
            )
        )
    }
}

@MainActor
private struct CloudPaneCreationFailureWindowBridge: NSViewRepresentable {
    let failure: CloudPaneCreationFailure?
    let isWorkspaceVisible: Bool
    let onRetry: ((UUID) -> Void)?
    let onDismiss: (UUID) -> Void

    func makeNSView(context: Context) -> CloudPaneCreationFailureOverlayHostView {
        let view = CloudPaneCreationFailureOverlayHostView(frame: .zero)
        view.isHidden = !isWorkspaceVisible
        view.update(failure: failure, onRetry: onRetry, onDismiss: onDismiss)
        return view
    }

    func updateNSView(_ nsView: CloudPaneCreationFailureOverlayHostView, context: Context) {
        nsView.isHidden = !isWorkspaceVisible
        nsView.update(failure: failure, onRetry: onRetry, onDismiss: onDismiss)
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(
        failure: CloudPaneCreationFailure?,
        onRetry: ((UUID) -> Void)?,
        onDismiss: @escaping (UUID) -> Void
    ) {
        pendingFailure = failure
        guard let failure else {
            removeCard()
            return
        }
        card.update(failure: failure, onRetry: onRetry, onDismiss: onDismiss)
        _ = ensureInstalled()
    }

    override var isHidden: Bool {
        didSet { _ = ensureInstalled() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        _ = ensureInstalled()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { removeCard() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { removeCard() }
        super.viewWillMove(toSuperview: newSuperview)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        _ = ensureInstalled()
    }

    func detach() {
        pendingFailure = nil
        removeCard()
    }

    private func removeCard() {
        NSLayoutConstraint.deactivate(installConstraints)
        installConstraints.removeAll()
        card.removeFromSuperview()
        installedContainer = nil
        installedReference = nil
    }

    @discardableResult
    private func ensureInstalled() -> Bool {
        guard pendingFailure != nil, !isHiddenOrHasHiddenAncestor,
              let window,
              let target = chromeComposition.contentOverlayTargetResolver.installationTarget(for: window) else {
            removeCard()
            return false
        }
        card.fit(width: min(420, max(160, bounds.width - 32)))
        if card.superview !== target.container || installedContainer !== target.container || installedReference !== target.reference {
            NSLayoutConstraint.deactivate(installConstraints)
            installConstraints.removeAll()
            card.removeFromSuperview()
            target.container.addSubview(card, positioned: .above, relativeTo: nil)
            installConstraints = [
                card.centerXAnchor.constraint(equalTo: centerXAnchor),
                card.centerYAnchor.constraint(equalTo: centerYAnchor),
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
    private let retryButton = NSButton(frame: .zero)
    private let dismissButton = NSButton(frame: .zero)
    private var currentFailure: CloudPaneCreationFailure?
    private var onRetry: ((UUID) -> Void)?
    private var onDismiss: ((UUID) -> Void)?
    private lazy var cardWidth = widthAnchor.constraint(equalToConstant: 420)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.38).cgColor
        updateBackgroundColor()
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

        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.title = String(localized: "common.retry", defaultValue: "Retry")
        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .regular
        retryButton.target = self
        retryButton.action = #selector(handleRetry)
        retryButton.setAccessibilityIdentifier("CloudPaneCreationFailureRetry")

        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.title = String(localized: "cloudPane.newTerminalFailed.ok", defaultValue: "OK")
        dismissButton.bezelStyle = .rounded
        dismissButton.controlSize = .regular
        dismissButton.target = self
        dismissButton.action = #selector(handleDismiss)
        dismissButton.keyEquivalent = "\u{1b}"
        dismissButton.keyEquivalentModifierMask = []
        dismissButton.setAccessibilityIdentifier("CloudPaneCreationFailureDismiss")

        let labels = NSStackView(views: [titleLabel, detailLabel, recoveryLabel])
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 6
        let actions = NSStackView(views: [retryButton, dismissButton])
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        addSubview(iconView)
        addSubview(labels)
        addSubview(actions)

        NSLayoutConstraint.activate([
            cardWidth,
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            labels.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            labels.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            titleLabel.widthAnchor.constraint(equalTo: labels.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: labels.widthAnchor),
            recoveryLabel.widthAnchor.constraint(equalTo: labels.widthAnchor),
            labels.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -14),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            actions.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
        setAccessibilityIdentifier("CloudPaneCreationFailure")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func fit(width: CGFloat) {
        if cardWidth.constant != width { cardWidth.constant = width }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackgroundColor()
    }

    private func updateBackgroundColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    func update(
        failure: CloudPaneCreationFailure,
        onRetry: ((UUID) -> Void)?,
        onDismiss: @escaping (UUID) -> Void
    ) {
        currentFailure = failure
        self.onRetry = onRetry
        self.onDismiss = onDismiss
        retryButton.isHidden = onRetry == nil
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

    @objc private func handleRetry() {
        guard let id = currentFailure?.id else { return }
        onRetry?(id)
    }
}
