import AppKit
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

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}

/// ``AgentPanePersonInput``'s check for code outside the agent pane (the join consent sheet's Allow): a
/// click or key another process posts, or an Accessibility press, is not the person's.
public struct PersonInputCheck: Sendable {
    public nonisolated init() {}
    /// Whether the event AppKit is dispatching now is the person's.
    @MainActor public var currentIsPerson: Bool { AgentPanePersonInput.currentIsPerson }
}
