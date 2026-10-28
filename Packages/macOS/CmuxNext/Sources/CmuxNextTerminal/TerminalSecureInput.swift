import AppKit
import Carbon.HIToolbox
public import CmuxNextTrace
import GhosttyNextKit

/// Secure keyboard entry requested by Ghostty (`GHOSTTY_ACTION_SECURE_INPUT`: the toggle keybind, or a password
/// prompt Ghostty detects). While any terminal holds it, the system's secure event input is on and the trace
/// runtime's keystroke-timing gate is held closed (``TraceRuntime/KeyTimingHold/terminalSecureInput``),
/// so no key timing is written, in the black box or a recording.
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

    /// The surface views that asked for secure input and still hold it.
    private var enabledViews: Set<ObjectIdentifier> = []
    private let trace: TraceRuntime
    private let system: System

    /// - Parameters:
    ///   - trace: The runtime whose keystroke-timing gate this holds closed while secure input is on.
    ///   - system: The system's secure event input switch.
    public init(trace: TraceRuntime, system: System = .carbon) {
        self.trace = trace
        self.system = system
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
        guard isEnabled != wasEnabled else { return }
        if isEnabled {
            trace.setKeyTimingSuppressed(true, by: .terminalSecureInput)
            system.enable()
        } else {
            lift()
        }
    }

    /// Lets go of `view`'s request when the view goes away.
    func release(_ view: ObjectIdentifier) {
        guard enabledViews.remove(view) != nil, enabledViews.isEmpty else { return }
        lift()
    }

    private func lift() {
        system.disable()
        trace.setKeyTimingSuppressed(false, by: .terminalSecureInput)
    }
}

extension TerminalSession {
    /// Whether this terminal holds secure keyboard entry now (a password prompt, the toggle keybind): what it
    /// shows must not reach a saved picture (`WindowPictureStore`).
    public var holdsSecureInput: Bool { surfaceView.secureInput.holds(ObjectIdentifier(surfaceView)) }
}
