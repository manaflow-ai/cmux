import AppKit
import CmuxNextControl
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// Gives the hover back once, whichever path gets there first (the run's end, an error, a
/// cancelled call, the person, the backstop timer); `how` says which. Only a release that went in
/// counts: one that failed leaves the hover held and the backstop armed, and a later path tries again.
@MainActor
final class DriveRelease {
    /// Sends the pointer-leave; true when it went in.
    private let send: @MainActor () async -> Bool
    /// A move went in, or is on its way, so there is a hover to give back.
    var armed = false
    /// The path whose release went in; nil until one did.
    private(set) var how: String?
    private(set) var released = false
    /// A release is being sent now (one at a time).
    private var sending = false
    /// The deadline that releases even when the run never gets there; dropped once a release went in.
    private var backstop: DemandTimer?

    init(input: AgentChatDriveInput) {
        send = { await input.release() }
    }

    init(send: @escaping @MainActor () async -> Bool) {
        self.send = send
    }

    var isDone: Bool { released }

    /// Arms the main-queue deadline `delay` from now. It holds this release until it fires or a release went in.
    func armBackstop(after delay: Duration) {
        let timer = DemandTimer(owner: "agent.chat-drive.release")
        timer.schedule(after: delay) { @MainActor in await self.release("timer") }
        backstop = timer
    }

    var isBackstopArmed: Bool { backstop?.isScheduled == true }

    func release(_ reason: String) async {
        guard !released, !sending else { return }
        sending = true
        defer { sending = false }
        // Nothing was moved: the page's hover is already the person's pointer's.
        guard armed ? await send() : true else { return }
        released = true
        how = reason
        backstop?.cancel()
        backstop = nil
    }
}

/// Whether the person is using the chat: their real pointer is over its pane (and no other window
/// covers it there), or their own key or click reached it within ``AgentChatDriveControl/personQuietSeconds``
/// (or, with `since`, after the run started).
@MainActor
struct DrivePerson {
    let view: AgentPaneView
    let window: NSWindow

    func isUsing(since started: TimeInterval?) -> Bool {
        let mouse = NSEvent.mouseLocation
        if AgentChatDriveInput.isTopmost(window, at: mouse),
           window.convertToScreen(view.convert(view.visibleRect, to: nil)).contains(mouse) { return true }
        let now = ProcessInfo.processInfo.systemUptime
        let quiet = AgentChatDriveControl.personQuietSeconds
        if let page = view.page {
            // The page's own record of a real key or button that reached it (page script cannot set it).
            guard let last = page.lastUserEventUptime else { return false }
            return now - last <= quiet || started.map { last >= $0 } == true
        }
        // The pane's own WebKit host keeps no such record: a key or click anywhere in the session
        // while this chat holds the keyboard in the key window counts as the person's.
        guard window.isKeyWindow, let responder = window.firstResponder as? NSView, responder.isDescendant(of: view) else { return false }
        let since = min(quiet, started.map { now - $0 } ?? quiet)
        return [CGEventType.keyDown, .leftMouseDown, .rightMouseDown].contains { type in
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type) <= since
        }
    }
}
