import AppKit
import os

/// Chromium's application protocols (base/message_loop/message_pump_apple.h,
/// include/cef_application_mac.h), declared under their Objective-C names.
/// The runtime keeps the first protocol registered under a name and remaps
/// later references to it, so the CEF shim's `@protocol(CefAppProtocol)` and
/// Chromium's `@protocol(CrAppProtocol)` resolve to these, and
/// `CmuxApplication` conforms statically: nothing is injected at runtime.
@objc(CrAppProtocol) protocol ChromiumAppProtocol: NSObjectProtocol {
    @objc(isHandlingSendEvent) func isHandlingSendEvent() -> Bool
}

@objc(CrAppControlProtocol) protocol ChromiumAppControlProtocol: ChromiumAppProtocol {
    @objc(setHandlingSendEvent:) func setHandlingSendEvent(_ handlingSendEvent: Bool)
}

@objc(CefAppProtocol) protocol CEFAppProtocol: ChromiumAppControlProtocol {}

/// The app's NSApplication.
///
/// - CEF: Chromium must know when an event is being dispatched through
///   `sendEvent:` (nested run loops, menu tracking), so this class tracks it
///   and conforms to `CefAppProtocol` before `CefInitialize`.
/// - Keys: every key-down of the process passes ``keyDownInterceptor`` (the
///   `KeyRouter`) before any window or responder, including Chromium page
///   windows that are key themselves, so system and navigation shortcuts
///   work whatever has focus (plans/cmux-next/focus.md section 5).
/// - `CMUX_NEXT_NO_ACTIVATE=1` (``refusesActivation``): every activation
///   request, from AppKit, CEF/Chromium, or app code, is dropped, so an agent
///   run never takes focus from the user's frontmost app.
final class CmuxApplication: NSApplication, CEFAppProtocol {
    private var handlingSendEvent = false
    /// Set once in `CmuxNextApp.main` before `run()`.
    var refusesActivation = false
    /// Set once by `AppServices`. Gets the key-down and the window it goes
    /// to; returns true when it consumed the key.
    var keyDownInterceptor: ((NSEvent, NSWindow?) -> Bool)?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app")

    @objc(isHandlingSendEvent)
    func isHandlingSendEvent() -> Bool { handlingSendEvent }

    @objc(setHandlingSendEvent:)
    func setHandlingSendEvent(_ value: Bool) { handlingSendEvent = value }

    override func sendEvent(_ event: NSEvent) {
        let previous = handlingSendEvent
        handlingSendEvent = true
        defer { handlingSendEvent = previous }
        if event.type == .keyDown, let keyDownInterceptor, keyDownInterceptor(event, keyWindow ?? event.window) { return }
        super.sendEvent(event)
    }

    // MARK: Accessibility windows

    /// The window Accessibility clients see as this app's focused or main
    /// window when `window` is key or main.
    static func accessibilityWindow(for window: NSWindow?) -> NSWindow? {
        window
    }

    override func accessibilityFocusedWindow() -> Any? {
        guard let window = Self.accessibilityWindow(for: keyWindow), window !== keyWindow else { return super.accessibilityFocusedWindow() }
        return window
    }

    override func accessibilityMainWindow() -> Any? {
        guard let window = Self.accessibilityWindow(for: keyWindow ?? mainWindow), window !== (keyWindow ?? mainWindow) else {
            return super.accessibilityMainWindow()
        }
        return window
    }

    // MARK: Activation

    override func activate() {
        guard !refusesActivation else { return logRefused() }
        super.activate()
    }

    /// Chromium and older AppKit paths still call this one.
    override func activate(ignoringOtherApps: Bool) {
        guard !refusesActivation else { return logRefused() }
        super.activate(ignoringOtherApps: ignoringOtherApps)
    }

    private func logRefused() {
        logger.info("activation refused (CMUX_NEXT_NO_ACTIVATE=1)")
    }
}
