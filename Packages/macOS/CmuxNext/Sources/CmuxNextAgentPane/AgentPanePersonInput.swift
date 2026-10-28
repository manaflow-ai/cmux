import AppKit
import CmuxNextInput
import Darwin

/// Whether a key or mouse event in an agent pane is the person's own input, for the pane's gesture
/// monitor (``AgentPaneUserGestures``; cx-ocdz). A click another process posts (CGEventPost: a
/// computer-use agent, a script) on the permission card's Allow must not count: only the person may
/// allow (cx-1l61), and the page answers whatever click reaches it.
///
/// The person's input comes from the HID system, whose events carry source pid 0. Besides that,
/// only the Apple services a person drives the Mac through (Screen Sharing, Universal Control, the
/// Accessibility Keyboard) count, named by their path under the SIP-protected /System. Never
/// System Events or any other Apple tool a script can drive. DEBUG automation (`debug.key`,
/// `debug.agent_pane click`) acts as the person on purpose, so this process's own events count in
/// DEBUG builds only.
enum AgentPanePersonInput {
    static let personServices = [
        "/System/Library/CoreServices/RemoteManagement/screensharingd.bundle/",
        "/System/Library/CoreServices/UniversalControl.app/",
        "/System/Library/CoreServices/AssistiveControl.app/",
    ]

    static func isPerson(_ event: NSEvent) -> Bool {
        guard let source = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) else { return false }
        if source == 0 { return true }
        #if DEBUG
        if source == Int64(getpid()) { return true }
        #endif
        guard let path = executablePath(pid_t(truncatingIfNeeded: source)) else { return false }
        return personServices.contains { path.hasPrefix($0) }
    }

    /// Whether the event the running action answers (a menu choice, a shortcut, a drop:
    /// ``InputEventTap/actionEvent``) is the person's; none (a CLI, socket or script run) is not.
    @MainActor static func isPerson(answering input: InputEventTap) -> Bool { input.actionEvent.map(isPerson) ?? false }

    /// Records the gesture of a native choice (a menu item, a shortcut, a drop) only when the event
    /// it answers is the person's: a posted click or key, or a scripted run, grants nothing.
    /// `answer`: the native permission shortcut, which may answer a prompt as a click does.
    @MainActor static func record(_ gestures: AgentPaneUserGestures, input: InputEventTap, if byPerson: Bool = true,
                                  answer: Bool = false) {
        if byPerson, isPerson(answering: input) { gestures.record(click: answer) }
    }

    /// How the drag a drop ends was ended, read as the drop lands. A drop has no event to judge:
    /// AppKit calls `performDragOperation` from the drag session, outside any dispatch, and the window
    /// server sends the destination no mouse event during a drag.
    struct DragEnd: Equatable {
        /// Seconds since the HID system's last button release. Posted events (CGEventPost) never move
        /// the HID state, only the session's.
        var sinceHIDRelease: TimeInterval
        /// Seconds since the login session's last button drag, posted ones included.
        var sinceSessionDrag: TimeInterval

        /// The person's drop: the HID system released the button after the drag's last move, so the
        /// person's hand ended the drag. A drag a script posts moves after the person's last release.
        var isPersons: Bool { sinceHIDRelease < sinceSessionDrag }

        /// Read now. The release is read first, so the time between the two reads never makes a
        /// posted drag look older than the person's release.
        static func now() -> DragEnd {
            let release = [CGEventType.leftMouseUp, .rightMouseUp, .otherMouseUp]
                .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
            let drag = [CGEventType.leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
                .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
            return DragEnd(sinceHIDRelease: release, sinceSessionDrag: drag)
        }
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        // SAFETY: proc_pidpath writes at most buffer.count bytes into the array's own storage, lent for the call.
        guard unsafe proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
