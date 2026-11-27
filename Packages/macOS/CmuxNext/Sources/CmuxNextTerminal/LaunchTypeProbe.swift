public import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// The first-keystroke probe of the launch harness (scripts/measure/launch-ready.sh `type=1`, which sets
/// `CMUX_NEXT_LAUNCH_TYPE_PROBE=1`): at the first window frame it types one space and one Delete into the key window
/// through the app's own event queue, as a person who types the moment the window shows. The keys take the path a
/// real key does (the key router, the window's key hold, the focused terminal), so the launch marks
/// `terminal_input_accepted` and `terminal_echo` (CmuxNextDaemon's LaunchInputMarks.swift) time that key into the
/// restored terminal and its echo back; the Delete leaves the shell's line as it was. It marks
/// `terminal.probe_key_typed` when it typed, or `terminal.probe_no_key_window` when the app had no window that could
/// take keys. Off (nil) without the variable; it types once.
///
/// A launch the system did not bring to the front has no key window at its first frame: the CI harness starts the
/// app from a background runner, which macOS does not let activate another app (every terminal round of the nightly
/// launch-tti leg failed on it). The probe then does what a Dock launch does, activates the app and makes its front
/// window key, and marks why, `terminal.probe_app_inactive` (the app was not active) or
/// `terminal.probe_window_not_key` (active, no key window), so the reading names the focus as the probe's.
///
/// `CMUX_NEXT_LAUNCH_TYPE_PROBE=chat` times the chat front the same way on a runner that may not post keys: one key
/// typed at the first frame lands before any chat page is up (the page watches keys from its first paint,
/// webviews launchInputEcho.ts), so the probe keeps typing the same space and Delete every ``chatEvery`` from the first
/// frame, as a person who types until the composer takes it, until ``stop()`` (the mark `agent_pane.input_echoed`)
/// or ``chatBound``. It marks `chat.probe_typing` when it starts, so the harness tells a build with this mode from one
/// without it. The interval the harness reads still starts at the process start.
@MainActor
public final class LaunchTypeProbe {
    nonisolated static let variable = "CMUX_NEXT_LAUNCH_TYPE_PROBE"

    nonisolated static let chatEvery: TimeInterval = 0.04  // launch_tti_check.py KEY_EVERY_S, the posted path's pace
    nonisolated static let chatBound: TimeInterval = 60

    private let mark: (String) -> Void
    /// The chat mode: type until ``stop()``.
    let typesUntilChatEcho: Bool
    private var stopped = false

    /// Nil unless `environment` turns the probe on (`1`, or `chat` for the chat front). `listen` registers for the
    /// chat's launch mark names (AgentPaneLaunchTimings `listen`): the chat mode stops at `agent_pane.input_echoed`.
    public init?(environment: [String: String], listen: (@escaping @Sendable (String) -> Void) -> Void,
                 mark: @escaping (String) -> Void) {
        switch environment[Self.variable] {
        case "1": typesUntilChatEcho = false
        case "chat": typesUntilChatEcho = true
        default: return nil
        }
        self.mark = mark
        guard typesUntilChatEcho else { return }
        listen { [self] name in
            if name == "agent_pane.input_echoed" { MainDelivery().run { self.stop() } }
        }
    }

    /// Types into the key window now (call it at the first window frame); in the chat mode, again every
    /// ``chatEvery`` until ``stop()`` or ``chatBound``.
    public func type() {
        guard typesUntilChatEcho else { return typeOnce() }
        mark("chat.probe_typing")
        typeChat(until: ProcessInfo.processInfo.systemUptime + Self.chatBound)
    }

    /// One key now, the next after ``chatEvery``; the pending call keeps the probe alive until it stops (bounded).
    private func typeChat(until end: TimeInterval) {
        guard !stopped, ProcessInfo.processInfo.systemUptime < end else { return }
        typeOnce()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.chatEvery) { MainDelivery().run { self.typeChat(until: end) } }
    }

    /// Ends the chat mode's typing (the composer drew a typed key).
    func stop() { stopped = true }

    private func typeOnce() {
        guard let window = NSApp.keyWindow ?? takeFront() else { return mark("terminal.probe_no_key_window") }
        for (characters, keyCode) in [(" ", UInt16(49)), ("\u{7f}", UInt16(51))] {
            for kind in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil, characters: characters,
                                                   charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
                else { continue }
                NSApp.postEvent(event, atStart: false)
            }
        }
        mark("terminal.probe_key_typed")
    }

    /// The front window that can take keys, made key with the app activated, as a Dock launch leaves it; nil when
    /// the app has none.
    private func takeFront() -> NSWindow? {
        guard let window = NSApp.orderedWindows.first(where: { $0.isVisible && $0.canBecomeKey }) else { return nil }
        mark(NSApp.isActive ? "terminal.probe_window_not_key" : "terminal.probe_app_inactive")
        let route = FocusRoute(.person, "launch probe: the front a Dock launch gives")
        route.activateApp()
        route.makeKey(window, front: true)
        return window
    }
}
