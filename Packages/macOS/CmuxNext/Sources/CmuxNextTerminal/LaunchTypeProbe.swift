public import AppKit
import CmuxNextDesign

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
/// The chat probe (`CMUX_NEXT_LAUNCH_TYPE_PROBE_CHAT=1`, scripts/ci/launch_tti_check.py's in_app chat rounds) types
/// the same two keys once more when the live chat first painted (`agent_pane.page_painted`): a key at the first frame
/// lands before any chat page is up, so the composer's echo mark `agent_pane.input_echoed` never came and every chat
/// round read no number. Its marks are `chat.probe_key_typed` and `chat.probe_no_key_window`.
///
/// The chat probe types its Delete only after the composer echoed the space (`agent_pane.input_echoed`): at the
/// chat's first paint the composer has not taken focus yet, so the key router queues the keys for it
/// (KeyRouter `typesAhead`), and a Delete typed behind a queued space removes it from the queue, as it should for a
/// person; the composer never changed and no chat round read an echo (6 of 6, job 141017485635). It also marks the
/// window the space went to, `chat.probe_window.page` (a page's own child window, which Chromium takes keys in) or
/// `chat.probe_window.shell` (the main window, whose key router hands the key on), so a round with no echo names it.
@MainActor
public final class LaunchTypeProbe {
    nonisolated static let variable = "CMUX_NEXT_LAUNCH_TYPE_PROBE"
    nonisolated static let chatVariable = "CMUX_NEXT_LAUNCH_TYPE_PROBE_CHAT"

    private let mark: (String) -> Void
    private let scope: String
    private var typed = false

    /// Nil unless `environment` turns the probe on.
    public init?(environment: [String: String], mark: @escaping (String) -> Void) {
        guard environment[Self.variable] == "1" else { return nil }
        self.mark = mark
        scope = "terminal"
    }

    /// The chat probe: nil unless `environment` turns it on. Call ``type()`` when the live chat first painted.
    public init?(chatEnvironment environment: [String: String], mark: @escaping (String) -> Void) {
        guard environment[Self.chatVariable] == "1" else { return nil }
        self.mark = mark
        scope = "chat"
    }

    /// Arms the chat probe when `environment` turns it on: it types once, on the main actor, when `listen` first tells
    /// of `agent_pane.page_painted` (AgentPaneLaunchTimings' mark listener). The saved snapshot also emits
    /// `agent_pane.painted`, before the live page installs its composer input watch; typing then loses the probe.
    /// Call it before any chat page loads.
    public static func armChat(environment: [String: String],
                               listen: (@escaping @Sendable (String) -> Void) -> Void,
                               mark: @escaping (String) -> Void) {
        guard let probe = LaunchTypeProbe(chatEnvironment: environment, mark: mark) else { return }
        listen { name in
            guard name == "agent_pane.page_painted" || name == "agent_pane.input_echoed" else { return }
            Task { @MainActor in probe.heard(name) }
        }
    }

    /// The chat probe heard `name`: the live chat's first paint types the space, the composer's echo of it the Delete.
    func heard(_ name: String) {
        if name == "agent_pane.page_painted" { type() } else { typeDelete() }
    }

    /// Types into the key window now (call it at the first window frame, the chat probe at the live chat's first paint).
    public func type() {
        guard !typed else { return }
        typed = true
        guard let window = NSApp.keyWindow ?? takeFront() else { return mark("\(scope).probe_no_key_window") }
        if scope == "chat" {
            mark(window.parent == nil ? "chat.probe_window.shell" : "chat.probe_window.page")
            post(Self.space, to: window)
            pendingDelete = true
        } else {
            post(Self.space + Self.delete, to: window)
        }
        mark("\(scope).probe_key_typed")
    }

    /// The chat probe's Delete, once the composer echoed its space: the composer is left as it was.
    public func typeDelete() {
        guard pendingDelete else { return }
        pendingDelete = false
        guard let window = NSApp.keyWindow else { return }
        post(Self.delete, to: window)
    }

    private var pendingDelete = false
    private static let space = [(" ", UInt16(49))]
    private static let delete = [("\u{7f}", UInt16(51))]

    private func post(_ keys: [(String, UInt16)], to window: NSWindow) {
        for (characters, keyCode) in keys {
            for kind in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil, characters: characters,
                                                   charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
                else { continue }
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    /// The front window that can take keys, made key with the app activated, as a Dock launch leaves it; nil when
    /// the app has none.
    private func takeFront() -> NSWindow? {
        guard let window = NSApp.orderedWindows.first(where: { $0.isVisible && $0.canBecomeKey }) else { return nil }
        mark(NSApp.isActive ? "\(scope).probe_window_not_key" : "\(scope).probe_app_inactive")
        let route = FocusRoute(.person, "launch probe: the front a Dock launch gives")
        route.activateApp()
        route.makeKey(window, front: true)
        return window
    }
}
