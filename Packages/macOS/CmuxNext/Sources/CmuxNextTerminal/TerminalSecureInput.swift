import AppKit
import Carbon.HIToolbox
public import CmuxNextTrace
import CmuxNextWakeups
import GhosttyNextKit

/// Secure keyboard entry requested by Ghostty (`GHOSTTY_ACTION_SECURE_INPUT`: the toggle keybind, or a password
/// prompt Ghostty detects). While any terminal holds a request, the trace runtime's keystroke-timing gate is held
/// closed (``TraceRuntime/KeyTimingHold/terminalSecureInput``, p09-observability-128), so no key timing is written,
/// in the black box or a recording. The system's secure event input is on only while a terminal that holds a
/// request has keyboard focus (``setFocused(_:for:)``) and the app is active (``setAppActive(_:)``): it is
/// process-wide and blocks other apps' key taps, so a password prompt in a background tab, another window or an
/// inactive cmux never holds it. Ghostty scopes it the same way
/// (`ghostty-next/macos/Sources/Features/Secure Input/SecureInput.swift`).
///
/// HIToolbox counts secure event input per process, so the process has one: ``GhosttyRuntime/secureInput``,
/// which each ``TerminalSession`` passes to its surfaces unless its owner injects another.
public final class TerminalSecureInput {
    /// The system's secure event input switch (tests pass their own).
    public struct System: Sendable {
        let enable: @Sendable () -> Void
        let disable: @Sendable () -> Void

        /// A switch that runs `enable` when the first terminal asks for secure input and `disable` when the
        /// last one lets it go.
        public init(enable: @escaping @Sendable () -> Void, disable: @escaping @Sendable () -> Void) {
            self.enable = enable
            self.disable = disable
        }

        /// HIToolbox's `EnableSecureEventInput` and `DisableSecureEventInput`.
        public static let carbon = System(enable: { _ = EnableSecureEventInput() }, disable: { _ = DisableSecureEventInput() })
    }

    /// The identity a surface view holds secure input under: an object the view owns for its life. A release
    /// that a deinit off the main thread posts (``releaseOnMain(_:)``) keeps it alive until it runs, so no new
    /// view can take its identity before the old request is let go (a view's own address can be reused at once).
    nonisolated final class Key: Sendable {
        var id: ObjectIdentifier { ObjectIdentifier(self) }
    }

    /// The surface views that asked for secure input and still hold it.
    private var enabledViews: Set<ObjectIdentifier> = []
    /// The surface views that have keyboard focus (first responder in the key window), as each reports it.
    private var focusedViews: Set<ObjectIdentifier> = []
    private var appActive: Bool
    /// Whether this turned the system's secure event input on (every enable is balanced by one disable).
    private var systemEnabled = false
    private let trace: TraceRuntime
    private let system: System

    /// - Parameters:
    ///   - trace: The runtime whose keystroke-timing gate this holds closed while secure input is on.
    ///   - system: The system's secure event input switch.
    ///   - appActive: Whether the app is active now; nil reads `NSApp.isActive`. ``setAppActive(_:)`` follows it.
    public init(trace: TraceRuntime, system: System = .carbon, appActive: Bool? = nil) {
        self.trace = trace
        self.system = system
        self.appActive = appActive ?? (NSApp?.isActive ?? false)
    }

    /// Whether any terminal holds secure input.
    var isEnabled: Bool { !enabledViews.isEmpty }

    /// Whether the surface view `view` holds secure input.
    func holds(_ view: ObjectIdentifier) -> Bool { enabledViews.contains(view) }

    /// Applies Ghostty's request for the surface view `view`: on, off, or a toggle of that view's request.
    func apply(_ mode: ghostty_action_secure_input_e, for view: ObjectIdentifier) {
        let wasEnabled = isEnabled
        switch mode {
        case GHOSTTY_SECURE_INPUT_ON: enabledViews.insert(view)
        case GHOSTTY_SECURE_INPUT_OFF: enabledViews.remove(view)
        default:
            if enabledViews.remove(view) == nil { enabledViews.insert(view) }
        }
        if isEnabled && !wasEnabled { trace.setKeyTimingSuppressed(true, by: .terminalSecureInput) }
        syncSystem()
        if !isEnabled && wasEnabled { trace.setKeyTimingSuppressed(false, by: .terminalSecureInput) }
    }

    /// Records whether the surface view `view` has keyboard focus now (its `updateFocus`).
    func setFocused(_ focused: Bool, for view: ObjectIdentifier) {
        if focused { focusedViews.insert(view) } else { focusedViews.remove(view) }
        syncSystem()
    }

    /// Follows the app's activation (`didBecomeActive` / `didResignActive`): an inactive app yields the
    /// system's secure input to the app the person uses, and takes it back when it is active again.
    func setAppActive(_ active: Bool) {
        appActive = active
        syncSystem()
    }

    /// Lets go of `view`'s request and focus when the view goes away.
    func release(_ view: ObjectIdentifier) {
        focusedViews.remove(view)
        let held = enabledViews.remove(view) != nil
        syncSystem()
        if held, enabledViews.isEmpty { trace.setKeyTimingSuppressed(false, by: .terminalSecureInput) }
    }

    /// ``release(_:)`` from any thread: at once on the main thread, else posted there. A surface view's deinit
    /// that runs off the main thread (its last reference dropped on another thread) calls it, so system secure
    /// input, which is process-wide, never stays on for a view that is gone.
    nonisolated func releaseOnMain(_ key: Key) {
        // main-hop-allow: only a deinit off the main thread hops; on main it runs inline in the release's turn
        MainDelivery().run { self.release(key.id) }
    }

    /// Turns the system's secure event input on or off to match: on while the app is active and a focused
    /// terminal holds a request.
    private func syncSystem() {
        let desired = appActive && !enabledViews.isDisjoint(with: focusedViews)
        guard desired != systemEnabled else { return }
        systemEnabled = desired
        if desired { system.enable() } else { system.disable() }
    }
}

extension TerminalSession {
    /// Whether this terminal holds secure keyboard entry now (a password prompt, the toggle keybind): what it
    /// shows must not reach a saved picture (`WindowPictureStore`).
    public var holdsSecureInput: Bool { surfaceView.secureInput.holds(surfaceView.secureInputKey.id) }
}
