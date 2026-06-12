import AppKit
import Bonsplit
import Combine
import SwiftUI

private final class DetachedNotificationsPopoverDelegate: NSObject, NSPopoverDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func popoverDidClose(_ notification: Notification) {
        onClose()
    }
}

@MainActor
final class UpdateTitlebarAccessoryController {
    private let updateLog: UpdateLogStore
    private var didStart = false
    private let attachedWindows = NSHashTable<NSWindow>.weakObjects()
    private var observers: [NSObjectProtocol] = []
    private var pendingAttachRetries: [ObjectIdentifier: Int] = [:]
    private var startupScanWorkItems: [DispatchWorkItem] = []
    private let controlsIdentifier = NSUserInterfaceItemIdentifier("cmux.titlebarControls")
    private let controlsControllers = NSHashTable<TitlebarControlsAccessoryViewController>.weakObjects()
    private var lastKnownPresentationMode: WorkspacePresentationModeSettings.Mode = WorkspacePresentationModeSettings.mode()
    private var detachedNotificationsPopover: NSPopover?
    private var detachedNotificationsPopoverDelegate: DetachedNotificationsPopoverDelegate?

    init(updateLog: UpdateLogStore) {
        self.updateLog = updateLog
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        attachToExistingWindows()
        installObservers()
        scheduleStartupWindowScans()
    }

    func attach(to window: NSWindow) {
        attachIfNeeded(to: window)
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            Task { @MainActor [weak self, weak window] in
                guard let window else { return }
                self?.attachIfNeeded(to: window)
            }
        })

        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            Task { @MainActor [weak self, weak window] in
                guard let window else { return }
                self?.attachIfNeeded(to: window)
            }
        })

        // Re-evaluate all windows when the presentation mode changes so that
        // accessories are removed in minimal mode and re-attached in standard mode.
        observers.append(center.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reattachIfPresentationModeChanged()
            }
        })

        // We intentionally do not rely on "window became visible" notifications here:
        // AppKit does not provide a stable cross-SDK API for this. Startup scans handle this case.
    }

    private func reattachIfPresentationModeChanged() {

        let currentMode = WorkspacePresentationModeSettings.mode()
        guard currentMode != lastKnownPresentationMode else { return }
        lastKnownPresentationMode = currentMode

        if currentMode == .standard {
            attachToExistingWindows()
        }
        for window in attachedWindows.allObjects {
            applyAccessoryVisibility(for: window)
        }
    }

    private func attachToExistingWindows() {
        for window in NSApp.windows {
            attachIfNeeded(to: window)
        }
    }

    private func scheduleStartupWindowScans() {
        // We want to be robust to SwiftUI/AppKit timing and to XCTest automation. Scanning
        // NSApp.windows briefly at startup is cheap and ensures accessories are attached even
        // if key/main/visible notifications are missed.
        let delays: [TimeInterval] = [0.05, 0.15, 0.3, 0.6, 1.0, 2.0, 3.0]
        for delay in delays {
            let item = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    self?.attachToExistingWindows()
                }
#if DEBUG
                let env = ProcessInfo.processInfo.environment
                if env["CMUX_UI_TEST_MODE"] == "1" {
                    let ids = NSApp.windows.map { $0.identifier?.rawValue ?? "<nil>" }
                    let delayText = String(format: "%.2f", delay)
                    self?.updateLog.append("startup window scan (delay=\(delayText)) count=\(NSApp.windows.count) ids=\(ids.joined(separator: ","))")
                }
#endif
            }
            startupScanWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    private func attachIfNeeded(to window: NSWindow) {
        guard NSApp.windows.contains(where: { $0 === window }) else {
            pendingAttachRetries.removeValue(forKey: ObjectIdentifier(window))
            return
        }
        guard !isSettingsWindow(window) else { return }

        // Window identifiers are assigned by SwiftUI via WindowAccessor, which can run
        // after didBecomeKey/didBecomeMain notifications. Retry briefly to avoid missing
        // attaching accessories (notably in UI tests).
        if !isMainTerminalWindow(window) {
            let key = ObjectIdentifier(window)
            let attempts = pendingAttachRetries[key, default: 0]
            if attempts < 40 {
                pendingAttachRetries[key] = attempts + 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak window] in
                    Task { @MainActor [weak self, weak window] in
                        guard let self, let window else { return }
                        self.attachIfNeeded(to: window)
                    }
                }
            } else {
                pendingAttachRetries.removeValue(forKey: key)
            }
            return
        }

        pendingAttachRetries.removeValue(forKey: ObjectIdentifier(window))
        guard canAccessTitlebarAccessories(on: window) else { return }

        // Don't re-attach controls if already attached.
        guard !attachedWindows.contains(window) else {
            applyAccessoryVisibility(for: window)
            return
        }

        if !window.titlebarAccessoryViewControllers.contains(where: { $0.view.identifier == controlsIdentifier }) {
            let controls = TitlebarControlsAccessoryViewController(
                notificationStore: TerminalNotificationStore.shared
            )
            controls.layoutAttribute = .left
            controls.view.identifier = controlsIdentifier
            window.addTitlebarAccessoryViewController(controls)
            controlsControllers.add(controls)
        }

        attachedWindows.add(window)
        applyAccessoryVisibility(for: window)

#if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["CMUX_UI_TEST_MODE"] == "1" {
            let ident = window.identifier?.rawValue ?? "<nil>"
            updateLog.append("attached titlebar accessories to window id=\(ident)")
        }
#endif
    }

    private func applyAccessoryVisibility(for window: NSWindow) {
        guard canAccessTitlebarAccessories(on: window) else {
            attachedWindows.remove(window)
            pendingAttachRetries.removeValue(forKey: ObjectIdentifier(window))
            return
        }
        let shouldHide = WorkspacePresentationModeSettings.mode() == .minimal
            || window.styleMask.contains(.fullScreen)
        for accessory in window.titlebarAccessoryViewControllers
            where accessory.view.identifier == controlsIdentifier {
            accessory.isHidden = shouldHide
            accessory.view.isHidden = shouldHide
            accessory.view.alphaValue = shouldHide ? 0 : 1
        }
    }

    private func isSettingsWindow(_ window: NSWindow) -> Bool {
        if window.identifier?.rawValue == "cmux.settings" {
            return true
        }
        return window.title == "Settings"
    }

    private func isMainTerminalWindow(_ window: NSWindow) -> Bool {
        guard let raw = window.identifier?.rawValue else { return false }
        return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
    }

    private func canAccessTitlebarAccessories(on window: NSWindow) -> Bool {
        isMainTerminalWindow(window) && window.styleMask.contains(.titled) && !isSettingsWindow(window)
    }

    private func preferredNotificationsController(
        from controllers: [TitlebarControlsAccessoryViewController],
        preferShownPopover: Bool
    ) -> TitlebarControlsAccessoryViewController? {
        if let keyWindow = NSApp.keyWindow,
           let match = controllers.first(where: { $0.view.window === keyWindow }) {
            return match
        }
        if let keyMain = NSApp.windows.first(where: { $0.isKeyWindow && isMainTerminalWindow($0) }),
           let match = controllers.first(where: { $0.view.window === keyMain }) {
            return match
        }
        if preferShownPopover,
           let shown = controllers.first(where: { $0.popoverIsShownForTesting }) {
            return shown
        }
        return controllers.first
    }

    func toggleNotificationsPopover(animated: Bool = true, anchorView: NSView? = nil) {
        let controllers = controlsControllers.allObjects

        // If an external anchor is provided (e.g. fullscreen sidebar controls),
        // use it for popover positioning instead of the hidden titlebar accessory.
        if let anchorView, anchorView.window != nil {
            let target = preferredNotificationsController(from: controllers, preferShownPopover: true)
            guard let target else {
                toggleDetachedNotificationsPopover(animated: animated, anchorView: anchorView)
                return
            }
            for controller in controllers where controller !== target {
                controller.dismissNotificationsPopover()
            }
            target.toggleNotificationsPopover(animated: animated, externalAnchor: anchorView)
            return
        }

        guard !controllers.isEmpty else { return }

        let target = preferredNotificationsController(from: controllers, preferShownPopover: true)
        for controller in controllers {
            if controller !== target {
                controller.dismissNotificationsPopover()
            }
        }
        target?.toggleNotificationsPopover(animated: animated)
    }

    private func toggleDetachedNotificationsPopover(animated: Bool, anchorView: NSView) {
        if let popover = detachedNotificationsPopover, popover.isShown {
            popover.animates = animated
            popover.performClose(nil)
            return
        }
        guard let window = anchorView.window,
              let contentView = window.contentView else {
            return
        }

        let popover = NSPopover()
        let delegate = DetachedNotificationsPopoverDelegate { [weak self, weak popover] in
            popover?.contentViewController = nil
            guard let self, self.detachedNotificationsPopover === popover else { return }
            self.detachedNotificationsPopover = nil
            self.detachedNotificationsPopoverDelegate = nil
            if let popover {
                postNotificationsPopoverVisibilityDidChange(isShown: false, source: popover)
            } else {
                postNotificationsPopoverVisibilityDidChange(isShown: false)
            }
        }
        popover.behavior = .semitransient
        popover.animates = animated
        popover.delegate = delegate
        popover.contentViewController = NSHostingController(
            rootView: NotificationsPopoverView(
                notificationStore: TerminalNotificationStore.shared,
                onDismiss: { [weak popover] in
                    popover?.performClose(nil)
                }
            )
        )

        contentView.layoutSubtreeIfNeeded()
        anchorView.superview?.layoutSubtreeIfNeeded()
        let anchorRect = anchorView.convert(anchorView.bounds, to: contentView)
        guard !anchorRect.isEmpty else { return }

        detachedNotificationsPopover = popover
        detachedNotificationsPopoverDelegate = delegate
        popover.show(relativeTo: anchorRect, of: contentView, preferredEdge: .maxY)
        postNotificationsPopoverVisibilityDidChange(
            isShown: true,
            source: popover,
            windowNumber: window.windowNumber
        )
    }

    func isNotificationsPopoverShown() -> Bool {
        detachedNotificationsPopover?.isShown == true ||
            controlsControllers.allObjects.contains(where: { $0.popoverIsShownForTesting })
    }

    @discardableResult
    func dismissNotificationsPopoverIfShown() -> Bool {
        let controllers = controlsControllers.allObjects
        var dismissed = false
        if let popover = detachedNotificationsPopover, popover.isShown {
            popover.performClose(nil)
            dismissed = true
        }
        for controller in controllers where controller.popoverIsShownForTesting {
            controller.dismissNotificationsPopover()
            dismissed = true
        }
        return dismissed
    }

    func showNotificationsPopover(animated: Bool = true) {
        let controllers = controlsControllers.allObjects
        guard !controllers.isEmpty else { return }

        let target = preferredNotificationsController(from: controllers, preferShownPopover: false)
        for controller in controllers {
            if controller !== target {
                controller.dismissNotificationsPopover()
            }
        }
        guard let target else { return }
        if target.popoverIsShownForTesting {
            return
        }
        target.toggleNotificationsPopover(animated: animated)
    }
}
