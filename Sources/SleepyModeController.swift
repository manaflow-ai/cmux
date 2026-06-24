import AppKit
import IOKit.pwr_mgt
import SwiftUI

/// Owns "Sleepy Mode": a full-screen cute-face screensaver plus IOKit power
/// assertions that keep the Mac (and its display) awake. Use case: leave the
/// Mac running so it can be driven from the cmux iOS app without it sleeping.
@MainActor
final class SleepyModeController: ReleasingWindowController {
    static let shared = SleepyModeController()

    private(set) var isActive = false

    /// Invoked whenever sleepy mode turns on or off so menu UI can refresh.
    var onStateChange: (() -> Void)?

    private var systemAssertionID = IOPMAssertionID(0)
    private var displayAssertionID = IOPMAssertionID(0)
    private var hasSystemAssertion = false
    private var hasDisplayAssertion = false

    private override init() {
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func toggle() {
        if isActive {
            deactivate()
        } else {
            activate()
        }
    }

    func activate() {
        guard !isActive else { return }
        beginPowerAssertions()
        let window = managedWindow()
        positionAcrossActiveScreen(window)
        NSApp.unhide(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        isActive = true
        onStateChange?()
    }

    func deactivate() {
        guard isActive else { return }
        // Closing the window funnels through managedWindowWillClose, which
        // releases the power assertions and flips isActive back to false.
        window?.close()
    }

    override func makeWindow() -> NSWindow {
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let window = SleepyOverlayWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.sleepyMode")
        window.isOpaque = true
        window.backgroundColor = .black
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.hidesOnDeactivate = false
        window.isMovable = false
        window.acceptsMouseMovedEvents = true
        window.onExit = { [weak self] in
            self?.deactivate()
        }
        window.contentView = NSHostingView(rootView: SleepyFaceView())
        return window
    }

    override func managedWindowWillClose(_ window: NSWindow) {
        endPowerAssertions()
        if isActive {
            isActive = false
            onStateChange?()
        }
    }

    private func positionAcrossActiveScreen(_ window: NSWindow) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let frame = screen?.frame {
            window.setFrame(frame, display: true)
        }
    }

    /// In-process equivalent of `caffeinate -d -i`: keep the display awake so the
    /// screensaver stays visible, and stop the system from idle-sleeping.
    var isHoldingPowerAssertions: Bool { hasSystemAssertion || hasDisplayAssertion }

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

/// Borderless overlay window that becomes key so any keypress or click wakes
/// the Mac and exits sleepy mode.
final class SleepyOverlayWindow: NSWindow {
    var onExit: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        onExit?()
    }

    override func mouseDown(with event: NSEvent) {
        onExit?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onExit?()
    }
}
