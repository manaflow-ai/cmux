import AppKit
import IOKit.pwr_mgt
import LocalAuthentication
import SwiftUI

/// Owns "Sleepy Mode": a secure full-screen cute-face lock that keeps the Mac
/// (and its display) awake. Use case: leave the Mac running so it can be driven
/// from the cmux iOS app, without letting a passerby touch the desktop.
///
/// Security model (kiosk lock, not a FileVault-grade lock):
/// - Covers every screen with a borderless screensaver-level overlay.
/// - Applies `NSApplicationPresentationOptions` kiosk flags that disable
///   Cmd-Tab, Mission Control/Exposé, the Force Quit panel, the power-key
///   restart/shutdown menu, app hiding, the Dock, and the menu bar.
/// - Swallows every key (including Cmd-Q) via a local event monitor while
///   locked, so the only way out is authentication.
/// - Requires Touch ID or the account password (`LocalAuthentication`) to exit.
///
/// The cmux daemon/socket keeps serving the iOS app while locked, since that
/// path never touches the GUI.
@MainActor
final class SleepyModeController {
    static let shared = SleepyModeController()

    private(set) var isActive = false
    private var locked = false

    /// True only while engaged as a secure lock (kiosk + auth required to exit).
    var isLocked: Bool { isActive && locked }

    /// Invoked whenever sleepy mode turns on or off so menu UI can refresh.
    var onStateChange: (() -> Void)?

    private var overlayWindows: [SleepyOverlayWindow] = []
    private var keyMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var savedPresentationOptions: NSApplication.PresentationOptions?
    private var isAuthenticating = false

    private var systemAssertionID = IOPMAssertionID(0)
    private var displayAssertionID = IOPMAssertionID(0)
    private var hasSystemAssertion = false
    private var hasDisplayAssertion = false

    /// Kiosk flags. This exact combination is the canonical "lock down
    /// everything" set; invalid combinations raise an uncatchable NSException,
    /// so it must not be edited casually (hideMenuBar requires hideDock, etc.).
    private static let kioskOptions: NSApplication.PresentationOptions = [
        .hideDock,
        .hideMenuBar,
        .disableAppleMenu,
        .disableProcessSwitching,
        .disableForceQuit,
        .disableSessionTermination,
        .disableHideApplication,
    ]

    private init() {}

    var isHoldingPowerAssertions: Bool { hasSystemAssertion || hasDisplayAssertion }

    func toggle() {
        if isActive {
            if locked { requestUnlock() } else { deactivate() }
        } else {
            activate()
        }
    }

    /// Engage Sleepy Mode using the user's settings (locks when "Require Touch
    /// ID to exit" is on, otherwise a casual screensaver that any key/click wakes).
    func activate() {
        activateInternal(locked: SleepyModeSettingsStore.shared.requireAuth)
    }

    /// Non-locking full-screen preview: shows the scene without the kiosk
    /// lockdown, and any key/click exits without authentication.
    func preview() {
        activateInternal(locked: false)
    }

    private func activateInternal(locked: Bool) {
        guard !isActive else { return }
        isActive = true
        self.locked = locked
        beginPowerAssertions()
        if locked {
            applyKioskPresentationOptions()
            installKeyMonitor()
        }
        installScreenObserver()
        rebuildOverlayWindows()
        NSApp.unhide(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        onStateChange?()
    }

    /// User-facing exit: requires Touch ID / password. Falls back to a plain
    /// exit only when no authentication is possible at all, to avoid lockout.
    func requestUnlock() {
        guard isActive, !isAuthenticating else { return }

        let context = LAContext()
        context.localizedCancelTitle = String(localized: "sleepyMode.unlockCancel", defaultValue: "Cancel")
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            // No biometrics and no password set: do not trap the user.
            deactivate()
            return
        }

        isAuthenticating = true
        let reason = String(localized: "sleepyMode.unlockReason", defaultValue: "Unlock cmux Sleepy Mode")
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] success, _ in
            Task { @MainActor in
                guard let self else { return }
                self.isAuthenticating = false
                if success {
                    self.deactivate()
                }
            }
        }
    }

    /// Force exit without authentication. Internal teardown path (also the
    /// DEBUG socket escape hatch); never reachable from the locked UI.
    func deactivate() {
        guard isActive else { return }
        isActive = false
        locked = false
        isAuthenticating = false
        removeKeyMonitor()
        removeScreenObserver()
        restorePresentationOptions()
        endPowerAssertions()
        tearDownOverlayWindows()
        onStateChange?()
    }

    // MARK: - Overlay windows

    private func rebuildOverlayWindows() {
        tearDownOverlayWindows()
        let screens = NSScreen.screens.isEmpty ? [NSScreen.main].compactMap { $0 } : NSScreen.screens
        for screen in screens {
            let window = makeOverlayWindow(for: screen)
            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
        overlayWindows.first?.makeKeyAndOrderFront(nil)
    }

    private func makeOverlayWindow(for screen: NSScreen) -> SleepyOverlayWindow {
        let window = SleepyOverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.sleepyMode")
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.hidesOnDeactivate = false
        window.isMovable = false
        window.acceptsMouseMovedEvents = true
        window.setFrame(screen.frame, display: true)
        window.onExit = { [weak self] in
            guard let self else { return }
            if self.locked { self.requestUnlock() } else { self.deactivate() }
        }
        window.contentView = NSHostingView(rootView: SleepyFaceView())
        return window
    }

    private func tearDownOverlayWindows() {
        for window in overlayWindows {
            window.onExit = nil
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }
        overlayWindows.removeAll()
    }

    // MARK: - Kiosk lockdown

    private func applyKioskPresentationOptions() {
        savedPresentationOptions = NSApp.presentationOptions
        NSApp.presentationOptions = Self.kioskOptions
    }

    private func restorePresentationOptions() {
        if let savedPresentationOptions {
            NSApp.presentationOptions = savedPresentationOptions
            self.savedPresentationOptions = nil
        } else {
            NSApp.presentationOptions = []
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isActive else { return event }
            // While the auth sheet is up, let it receive keystrokes (password
            // fallback). Otherwise swallow every key — including Cmd-Q — and
            // route the interaction to the unlock prompt.
            if self.isAuthenticating { return event }
            self.requestUnlock()
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func installScreenObserver() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                self.rebuildOverlayWindows()
            }
        }
    }

    private func removeScreenObserver() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }

    // MARK: - Power assertions

    /// In-process equivalent of `caffeinate -d -i`: keep the display awake so the
    /// screensaver stays visible, and stop the system from idle-sleeping.
    private func beginPowerAssertions() {
        let reason = "cmux Sleepy Mode" as CFString
        if !hasSystemAssertion {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &id
            )
            if result == kIOReturnSuccess {
                systemAssertionID = id
                hasSystemAssertion = true
            }
            #if DEBUG
            cmuxDebugLog("sleepyMode.assertion.system result=\(result) id=\(id) ok=\(hasSystemAssertion)")
            #endif
        }
        if !hasDisplayAssertion {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &id
            )
            if result == kIOReturnSuccess {
                displayAssertionID = id
                hasDisplayAssertion = true
            }
            #if DEBUG
            cmuxDebugLog("sleepyMode.assertion.display result=\(result) id=\(id) ok=\(hasDisplayAssertion)")
            #endif
        }
    }

    private func endPowerAssertions() {
        if hasSystemAssertion {
            IOPMAssertionRelease(systemAssertionID)
            hasSystemAssertion = false
            systemAssertionID = IOPMAssertionID(0)
        }
        if hasDisplayAssertion {
            IOPMAssertionRelease(displayAssertionID)
            hasDisplayAssertion = false
            displayAssertionID = IOPMAssertionID(0)
        }
    }
}

/// Borderless overlay window that becomes key so clicks route to the unlock
/// prompt. Keystrokes are handled by the controller's local event monitor.
final class SleepyOverlayWindow: NSWindow {
    var onExit: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        // In locked mode the controller's local monitor swallows keys before
        // they reach here; this path serves casual/preview mode.
        onExit?()
    }

    override func mouseDown(with event: NSEvent) {
        onExit?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onExit?()
    }
}
