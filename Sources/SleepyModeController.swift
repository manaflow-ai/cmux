import AppKit
import CmuxSettingsUI
import IOKit.pwr_mgt
import SwiftUI

/// Owns "Sleepy Mode": a cute full-screen keep-awake screensaver. It holds
/// IOKit power assertions so the Mac (and its display) stay awake — useful for
/// leaving the Mac running for the cmux iOS app — and covers every screen with
/// the animated scene.
///
/// It is deliberately NOT a security boundary: a normal macOS app cannot make
/// an unbypassable lock (the kiosk approach is escapable the moment another app
/// takes focus). Any key or click wakes it. For real security, the scene's
/// "Lock Mac" button triggers the actual macOS login lock.
@MainActor
final class SleepyModeController {
    static let shared = SleepyModeController()

    /// The single Sleepy Mode settings store, owned here (the app composition
    /// root) and injected into the overlay scene and the Preferences section.
    let store = SleepyModeSettingsStore()

    /// Power-action service (display sleep / real Mac lock / Low Power), owned
    /// here and injected into the scene; swap the runner for tests.
    let powerControls: any SleepyPowerControlling = SleepyPowerControls()

    private(set) var isActive = false

    /// Invoked whenever sleepy mode turns on or off so menu UI can refresh.
    var onStateChange: (() -> Void)?

    private var overlayWindows: [SleepyOverlayWindow] = []
    private var screenObserver: NSObjectProtocol?

    private var systemAssertionID = IOPMAssertionID(0)
    private var displayAssertionID = IOPMAssertionID(0)
    private var hasSystemAssertion = false
    private var hasDisplayAssertion = false

    private init() {}

    var isHoldingPowerAssertions: Bool { hasSystemAssertion || hasDisplayAssertion }

    /// True only when BOTH keep-awake assertions are held (system idle sleep and
    /// display sleep). Drives the honest on-screen badge — if either failed, the
    /// UI must not claim the Mac is safely staying awake.
    var keepAwakeFullyActive: Bool { hasSystemAssertion && hasDisplayAssertion }

    func toggle() {
        if isActive { deactivate() } else { activate() }
    }

    /// Shows the screensaver and keeps the Mac awake. Any key/click wakes it.
    func activate() {
        guard !isActive else { return }
        isActive = true
        beginPowerAssertions()
        installScreenObserver()
        rebuildOverlayWindows()
        NSApp.unhide(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        onStateChange?()
    }

    /// Same thing — kept as a distinct entry point for the settings "Preview"
    /// button now that there is no lock distinction.
    func preview() {
        activate()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        removeScreenObserver()
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
        window.onExit = { [weak self] in self?.deactivate() }
        window.contentView = NSHostingView(rootView: SleepyFaceView(store: store, power: powerControls, keepingAwake: keepAwakeFullyActive))
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
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id) == kIOReturnSuccess {
                systemAssertionID = id
                hasSystemAssertion = true
            }
        }
        if !hasDisplayAssertion {
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id) == kIOReturnSuccess {
                displayAssertionID = id
                hasDisplayAssertion = true
            }
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

/// Borderless screensaver window. Any key or click wakes it (no lock).
final class SleepyOverlayWindow: NSWindow {
    var onExit: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) { onExit?() }
    override func mouseDown(with event: NSEvent) { onExit?() }
    override func rightMouseDown(with event: NSEvent) { onExit?() }
}
