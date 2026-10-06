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
    /// Set once in `CmuxNextApp.shared.main` before `run()`.
    var refusesActivation = false
    /// Set once by `AppServices`. Gets the key-down and the window it goes
    /// to; returns true when it consumed the key.
    var keyDownInterceptor: ((NSEvent, NSWindow?) -> Bool)?
    /// Set once by `AppServices`: sees every event first (input journal).
    var inputObserver: ((NSEvent) -> Void)?
    /// Set once by `AppServices`: a mouse-down after AppKit dispatched it
    /// (focus has moved to the clicked pane), with its window.
    var mouseDownObserver: ((NSEvent) -> Void)?
    /// The event in dispatch is the app's own synthetic input
    /// (`SyntheticInput`, `debug.mouse`), classified once per event: the
    /// no-activate guard and the browser host's user-input path both read it.
    private(set) var currentEventIsSynthetic = false
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app")

    @objc(isHandlingSendEvent)
    func isHandlingSendEvent() -> Bool { handlingSendEvent }

    @objc(setHandlingSendEvent:)
    func setHandlingSendEvent(_ value: Bool) { handlingSendEvent = value }

    override func sendEvent(_ event: NSEvent) {
        let previousSynthetic = currentEventIsSynthetic
        currentEventIsSynthetic = !SyntheticInput.isUserInput(event)
        defer { currentEventIsSynthetic = previousSynthetic }
        inputObserver?(event)
        let previous = handlingSendEvent
        handlingSendEvent = true
        defer { handlingSendEvent = previous }
        if event.type == .keyDown {
            // Router-consumed keys never reach AppKit local event monitors.
            (Self.accessibilityWindow(for: keyWindow ?? event.window)?.windowController as? WindowController)?.hideShortcutHintsForKeyDown()
        }
        if event.type == .keyDown, let keyDownInterceptor, keyDownInterceptor(event, keyWindow ?? event.window) { return }
        super.sendEvent(event)
        if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown { mouseDownObserver?(event) }
    }

    // MARK: Accessibility windows

    /// The window Accessibility clients see as this app's focused or main
    /// window when `window` is key or main. A Chromium page is a child
    /// `NSWindow` that becomes key while the page has the keyboard; window
    /// managers (Rectangle) move the AX focused window, so they must get the
    /// cmux window that owns the page, which carries the page with it. App
    /// panels (palette, editors) stay their own windows.
    static func accessibilityWindow(for window: NSWindow?) -> NSWindow? {
        var current = window
        while let child = current, !(child is NSPanel), let parent = child.parent { current = parent }
        return current
    }

    /// AppKit reports the key window, or with none the frontmost ordered
    /// window, which is a Chromium page window when a page is in front.
    override func accessibilityFocusedWindow() -> Any? {
        Self.redirect(super.accessibilityFocusedWindow())
    }

    override func accessibilityMainWindow() -> Any? {
        Self.redirect(super.accessibilityMainWindow())
    }

    private static func redirect(_ value: Any?) -> Any? {
        guard let window = value as? NSWindow else { return value }
        return accessibilityWindow(for: window)
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
