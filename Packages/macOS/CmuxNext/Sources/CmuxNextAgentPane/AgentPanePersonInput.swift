public import AppKit
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

    /// Whether the event AppKit is dispatching now (a menu choice, a shortcut, a drop) is the
    /// person's; none (a call from outside an event) is not.
    @MainActor static var currentIsPerson: Bool { NSApp.currentEvent.map(isPerson) ?? false }

    /// Records the gesture of a native choice (a menu item, a shortcut, a drop) only when the event
    /// in dispatch is the person's: a posted click or key, or a scripted run, grants nothing.
    /// `answer`: the native permission shortcut, which may answer a prompt as a click does.
    @MainActor static func record(_ gestures: AgentPaneUserGestures, if byPerson: Bool = true, answer: Bool = false) {
        if byPerson, currentIsPerson { gestures.record(click: answer) }
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}

/// The strict check for a grant made on this Mac's own screen (the join consent sheet's Allow): only
/// input from the HID system counts. The event's source pid (`kCGEventSourceUnixProcessID`) must be 0 or
/// the WindowServer's, and its source state (`kCGEventSourceStateID`) the HID system's. So a click any
/// other process posts (CGEventPost, CGEventPostToPid, SkyLight's SLEventPostToPid: the cmux-cua helper
/// and `cmux-cua serve` post this way, and so can an agent's script), this process's own (DEBUG
/// automation included), and the Apple services the agent pane accepts (Screen Sharing, Universal
/// Control, the Accessibility Keyboard) never count here.
///
/// Limits: both fields are read from the event as it arrives. A poster's private or combined-session
/// source is refused, but a poster that makes a HID-state source (the cmux-cua helper does) matches on
/// the state, so the pid is what refuses it. Whether the window server overwrites a source pid that a
/// poster sets itself is not documented; this check takes the field as it arrives.
public struct PersonInputCheck: Sendable {
    static let windowServer = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer"

    public nonisolated init() {}

    /// Whether `event` is the person's own input from the HID system.
    @MainActor public func isPerson(_ event: NSEvent) -> Bool {
        guard let cgEvent = event.cgEvent,
              cgEvent.getIntegerValueField(.eventSourceStateID) == Int64(CGEventSourceStateID.hidSystemState.rawValue) else { return false }
        let source = cgEvent.getIntegerValueField(.eventSourceUnixProcessID)
        if source == 0 { return true }
        guard source > 0, source != Int64(getpid()) else { return false }
        return AgentPanePersonInput.executablePath(pid_t(truncatingIfNeeded: source)) == Self.windowServer
    }
}
