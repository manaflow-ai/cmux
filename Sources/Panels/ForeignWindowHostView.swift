import AppKit
import Foundation

/// Marks a pane rect for a profile's foreign window. The view leases the
/// profile from the registry while it exists; it never owns the process, so
/// SwiftUI teardown (pane moves, split drags, workspace moves) only detaches.
@MainActor
final class ForeignWindowHostView: NSView, ForeignWindowProfileHost {
    private static let observedHostWindowNotifications: [Notification.Name] = [
        NSWindow.didMoveNotification,
        NSWindow.didResizeNotification,
        NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification,
        NSWindow.didChangeScreenNotification,
        NSWindow.didBecomeKeyNotification
    ]

    private let hostID = UUID()
    private let panelID: UUID
    private let profile: String
    private let registry: ForeignWindowProfileRegistry
    private let placeholderLabel: NSTextField
    private var isAttached = false
    private var isDetached = false
    private var isPresenting = false
    private var isFocused = false
    private var isVisibleInUI = false
    private var lastReportedVisibility = false
    private weak var observedHostWindow: NSWindow?
    /// Clicking the placeholder focuses this pane, which moves the window here.
    var onRequestPanelFocus: (() -> Void)?

    init(
        panelID: UUID,
        profile: String,
        registry: ForeignWindowProfileRegistry
    ) {
        self.panelID = panelID
        self.profile = profile
        self.registry = registry
        self.placeholderLabel = NSTextField(
            wrappingLabelWithString: String(
                localized: "foreignWindow.placeholder.shownInOtherPane",
                defaultValue: "This account is open in another pane. Focus this pane to show it here."
            )
        )
        super.init(frame: .zero)
        wantsLayer = true
        configurePlaceholder()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cmuxApplicationBecameActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installHostWindowObservers()
        syncPresentation(raiseExternalWindow: isFocused)
    }

    override func mouseDown(with event: NSEvent) {
        if !isPresenting {
            onRequestPanelFocus?()
        }
        super.mouseDown(with: event)
    }

    override func layout() {
        super.layout()
        // Cheap: the session coalesces AX writes and skips unchanged rects.
        syncPresentation(raiseExternalWindow: false)
    }

    func update(
        isFocused: Bool,
        isVisibleInUI: Bool,
        backgroundColor: NSColor
    ) {
        let becameFocused = isFocused && !self.isFocused
        let becameVisible = isVisibleInUI && !self.isVisibleInUI
        self.isFocused = isFocused
        self.isVisibleInUI = isVisibleInUI
        layer?.backgroundColor = backgroundColor.cgColor
        syncPresentation(
            raiseExternalWindow: becameFocused || becameVisible
        )
    }

    /// View teardown: releases the lease only. The process keeps running
    /// until its panel is closed.
    func detach() {
        guard !isDetached else { return }
        isDetached = true
        removeHostWindowObservers()
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
        if isAttached {
            registry.detach(hostID: hostID)
            isAttached = false
        }
        isPresenting = false
        onRequestPanelFocus = nil
    }

    // MARK: ForeignWindowProfileHost

    func foreignWindowProfileHostDidChangePresenting(_ isPresenting: Bool) {
        self.isPresenting = isPresenting
        updatePlaceholderVisibility()
    }

    // MARK: Private

    private func configurePlaceholder() {
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.alignment = .center
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        placeholderLabel.isHidden = true
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: 16
            ),
            placeholderLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -16
            )
        ])
    }

    private func updatePlaceholderVisibility() {
        let shouldShowPlaceholder = lastReportedVisibility
            && isAttached
            && !isPresenting
        if placeholderLabel.isHidden == shouldShowPlaceholder {
            placeholderLabel.isHidden = !shouldShowPlaceholder
        }
    }

    private func attachIfNeeded() {
        guard !isAttached, !isDetached else { return }
        registry.attach(
            host: self,
            hostID: hostID,
            panelID: panelID,
            profile: profile
        )
        isAttached = true
    }

    private func installHostWindowObservers() {
        guard observedHostWindow !== window else { return }
        removeHostWindowObservers()
        guard let window, !isDetached else { return }
        observedHostWindow = window
        let center = NotificationCenter.default
        for name in Self.observedHostWindowNotifications {
            center.addObserver(
                self,
                selector: #selector(hostWindowChanged(_:)),
                name: name,
                object: window
            )
        }
    }

    private func removeHostWindowObservers() {
        guard let observedHostWindow else { return }
        let center = NotificationCenter.default
        for name in Self.observedHostWindowNotifications {
            center.removeObserver(
                self,
                name: name,
                object: observedHostWindow
            )
        }
        self.observedHostWindow = nil
    }

    @objc private func hostWindowChanged(_ notification: Notification) {
        let shouldRaise = notification.name == NSWindow.didBecomeKeyNotification
            || notification.name == NSWindow.didDeminiaturizeNotification
        syncPresentation(raiseExternalWindow: shouldRaise)
    }

    @objc private func cmuxApplicationBecameActive(_ notification: Notification) {
        _ = notification
        syncPresentation(raiseExternalWindow: true)
    }

    private func syncPresentation(raiseExternalWindow: Bool) {
        guard !isDetached else { return }
        attachIfNeeded()
        let hostWindowVisible = window?.isVisible == true
            && window?.isMiniaturized == false
        let shouldShow = isVisibleInUI && hostWindowVisible
        lastReportedVisibility = shouldShow
        registry.updateHost(
            hostID: hostID,
            isVisible: shouldShow,
            isFocused: isFocused,
            targetFrame: shouldShow ? accessibilityScreenFrame() : nil,
            raiseWindow: raiseExternalWindow
        )
        updatePlaceholderVisibility()
    }

    private func accessibilityScreenFrame() -> CGRect? {
        guard let window else { return nil }
        let windowRect = convert(bounds, to: nil)
        let appKitScreenRect = window.convertToScreen(windowRect)
        guard appKitScreenRect.width >= 1,
              appKitScreenRect.height >= 1 else {
            return nil
        }

        // AppKit uses a bottom-left global origin while AX window coordinates
        // use a top-left origin relative to the primary display.
        let primaryScreenTop = NSScreen.screens.first?.frame.maxY
            ?? appKitScreenRect.maxY
        return CGRect(
            x: appKitScreenRect.minX,
            y: primaryScreenTop - appKitScreenRect.maxY,
            width: appKitScreenRect.width,
            height: appKitScreenRect.height
        )
    }
}
