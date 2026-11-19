public import AppKit

/// The first-keystroke probe of the launch harness (scripts/measure/launch-ready.sh `type=1`, which sets
/// `CMUX_NEXT_LAUNCH_TYPE_PROBE=1`): at the first window frame it types one space and one Delete into the key window
/// through the app's own event queue, as a person who types the moment the window shows. The keys take the path a
/// real key does (the key router, the window's key hold, the focused terminal), so the launch marks
/// `terminal_input_accepted` and `terminal_echo` (CmuxNextDaemon's LaunchInputMarks.swift) time that key into the
/// restored terminal and its echo back; the Delete leaves the shell's line as it was. It marks
/// `terminal.probe_key_typed` when it typed, or `terminal.probe_no_key_window` when no window was key at that frame
/// (a person's key would have gone to another app). Off (nil) without the variable; it types once.
@MainActor
public final class LaunchTypeProbe {
    nonisolated static let variable = "CMUX_NEXT_LAUNCH_TYPE_PROBE"

    private let mark: (String) -> Void

    /// Nil unless `environment` turns the probe on.
    public init?(environment: [String: String], mark: @escaping (String) -> Void) {
        guard environment[Self.variable] == "1" else { return nil }
        self.mark = mark
    }

    /// Types into the key window now (call it at the first window frame).
    public func type() {
        guard let window = NSApp.keyWindow else { return mark("terminal.probe_no_key_window") }
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
}
