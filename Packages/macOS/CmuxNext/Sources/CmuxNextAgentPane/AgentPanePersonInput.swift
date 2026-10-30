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
    @MainActor static func record(_ gestures: AgentPaneUserGestures, if byPerson: Bool = true, answer: Bool = false,
                                 event: NSEvent? = NSApp.currentEvent) {
        if byPerson, let event, isPerson(event) { gestures.record(click: answer) }
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

/// The app's latest key or mouse input and whether ``PersonInputCheck`` calls it the person's, so a grant
/// a page makes (Settings > Devices' join consent switches) can tell whether the gesture behind it was
/// the HID system's: a page sees only that some real event reached it, not who posted it. A local event
/// monitor sees every key and mouse event the app dispatches, from either page engine, before the page.
/// Started once at launch and stopped with ``stop()`` (the app keeps it for its whole run).
@MainActor public final class PersonInputLedger {
    /// What a page counts as its gesture (``PageWKWebView``'s key and mouse events), and more.
    public static let types: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp,
                                                      .otherMouseDown, .otherMouseUp, .keyDown, .keyUp]
    /// The latest input: its `timestamp` (system uptime) and whether it was the person's.
    public private(set) var last: (uptime: TimeInterval, person: Bool)?
    private let check: @MainActor (NSEvent) -> Bool
    private var monitor: Any?

    public init(check: @escaping @MainActor (NSEvent) -> Bool = { PersonInputCheck().isPerson($0) }) {
        self.check = check
    }

    public func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: Self.types) { [weak self] event in
            // AppKit calls a local monitor on the main thread; anywhere else, nothing is recorded, so no
            // grant is backed (fail closed).
            guard Thread.isMainThread else { return event }
            // main-proof: guarded by Thread.isMainThread above (AppKit calls local monitors on main; it records before the page sees the event)
            MainActor.assumeIsolated { self?.record(event) }
            return event
        }
    }

    public func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    public func record(_ event: NSEvent) {
        last = (event.timestamp > 0 ? event.timestamp : ProcessInfo.processInfo.systemUptime, check(event))
    }

    /// SECURITY: the page gesture at `uptime` is the person's own: the app's latest input is the person's,
    /// at or before it (within a second, as a page keeps a gesture), and no input of anyone else's came
    /// after it. A click another process posts, even right after one of the person's, backs nothing.
    public func backs(_ uptime: TimeInterval) -> Bool {
        guard let last, last.person else { return false }
        return last.uptime <= uptime + 0.001 && uptime - last.uptime <= 1
    }
}
