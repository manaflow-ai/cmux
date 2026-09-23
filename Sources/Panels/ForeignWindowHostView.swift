import AppKit
import Foundation

@MainActor
final class ForeignWindowHostView: NSView {
    private let externalSession: ForeignWindowSession
    private var isFocused = false
    private var isVisibleInUI = false
    private weak var observedHostWindow: NSWindow?

    init(
        surfaceID: UUID,
        launchConfiguration: ForeignWindowLaunchConfiguration
    ) {
        self.externalSession = ForeignWindowSession(
            surfaceID: surfaceID,
            launchConfiguration: launchConfiguration
        )
        super.init(frame: .zero)
        wantsLayer = true
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
        externalSession.startIfNeeded()
        syncPresentation(raiseExternalWindow: isFocused)
    }

    override func layout() {
        super.layout()
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
        externalSession.startIfNeeded()
        syncPresentation(
            raiseExternalWindow: becameFocused || becameVisible
        )
    }

    func invalidate() {
        removeHostWindowObservers()
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
        externalSession.invalidate()
    }

    private func installHostWindowObservers() {
        guard observedHostWindow !== window else { return }
        removeHostWindowObservers()
        guard let window else { return }
        observedHostWindow = window
        let center = NotificationCenter.default
        for name in [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didBecomeKeyNotification
        ] {
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
        for name in [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didBecomeKeyNotification
        ] {
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
        let hostWindowVisible = window?.isVisible == true
            && window?.isMiniaturized == false
        let shouldShow = isVisibleInUI && hostWindowVisible
        externalSession.updatePresentation(
            targetFrame: shouldShow ? accessibilityScreenFrame() : nil,
            isVisible: shouldShow,
            isFocused: isFocused,
            raiseWindow: raiseExternalWindow
        )
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
