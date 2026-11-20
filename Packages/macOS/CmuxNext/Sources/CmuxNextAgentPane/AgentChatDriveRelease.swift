import AppKit
import CmuxNextControl
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// Gives the hover back, once, whichever path gets there first: the run's end, an error, a cancelled
/// call, the person, the backstop timer, or a trigger from outside the run (the tab closing, the window
/// closing, the app resigning active); `how` says which. Only a release that went in counts, and one
/// that can't is retried, bounded: after a failed send it waits ``retryWaits`` (50 ms doubling to 1 s,
/// 9 sends in about 4.5 s). One round runs at a time; a release asked for during a round joins it.
/// A view that is gone (``AgentChatDriveInput/ReleaseOutcome/gone``) holds no hover: that counts as
/// released by `teardown`. Past the cap the release stays pending, registered on its view
/// (``AgentPaneView/heldDrives``), and the view's next trigger (back in a window, the tab closing)
/// runs another round. The registration lasts until a release went in. The run itself reads the
/// window and the app (``DriveSurroundings``) with the person: no observer of its own.
@MainActor
final class DriveRelease {
    typealias Outcome = AgentChatDriveInput.ReleaseOutcome

    /// The waits between the sends of one round.
    static let retryWaits: [Duration] = [50, 100, 200, 400, 800, 1000, 1000, 1000].map { Duration.milliseconds($0) }
    /// The triggers that stop a run that is still going (`interrupted`); the others only retry a pending release.
    static let interrupting: Set<String> = ["teardown", "window_close", "resign", "detached"]
    /// The trigger that can make a send go in that failed before (the view back in a window): one that
    /// comes while a round runs gets a round of its own after it, never only the rest of that one. A
    /// teardown needs none: the round ends at its next send (``tornDown``).
    static let fresh: Set<String> = ["window"]

    /// Sends the pointer-leave.
    private let send: @MainActor () async -> Outcome
    /// Waits between two sends of a round (tests pass their own).
    private let sleep: @MainActor (Duration) async -> Void
    /// A move went in, or is on its way, so there is a hover to give back.
    var armed = false
    /// The run returned: a trigger from now on only retries the release.
    var runEnded = false
    /// The path whose release went in; nil until one did.
    private(set) var how: String?
    private(set) var released = false
    /// The first trigger from outside the run while it was still going; the run stops at it.
    private(set) var triggered: String?
    /// The sends made, for the report and tests.
    private(set) var sends = 0
    /// The round running now; a release asked for meanwhile waits for it.
    private var round: Task<Void, Never>?
    /// The tab closed: whatever the next send does, nothing is left to hold.
    private var tornDown = false
    /// The deadline that releases even when the run never gets there; dropped once a release went in.
    private var backstop: DemandTimer?
    private weak var view: AgentPaneView?

    init(input: AgentChatDriveInput) {
        send = { await input.release() }
        sleep = DriveRelease.pause
    }

    init(send: @escaping @MainActor () async -> Outcome, sleep: @escaping @MainActor (Duration) async -> Void = DriveRelease.pause) {
        self.send = send
        self.sleep = sleep
    }

    static func pause(_ delay: Duration) async {
        // wakeup-allow: one wait between two release sends (at most 1 s, 8 a round), in the round's own task
        try? await Task.sleep(for: delay)
    }

    var isDone: Bool { released }

    /// Arms the main-queue deadline `delay` from now. It holds this release until it fires or a release went in.
    func armBackstop(after delay: Duration) {
        let timer = DemandTimer(owner: "agent.chat-drive.release")
        timer.schedule(after: delay) { @MainActor in await self.release("timer") }
        backstop = timer
    }

    var isBackstopArmed: Bool { backstop?.isScheduled == true }

    /// Registers on `view` until a release went in: the tab closing and the view moving between
    /// windows (``AgentPaneView/heldDrives``) trigger it.
    func register(on view: AgentPaneView) {
        guard !released else { return }
        self.view = view
        view.heldDrives[ObjectIdentifier(self)] = self
    }

    /// Something outside the run happened (`teardown`, `window_close`, `resign`, `detached`, `window`).
    /// A run still going stops at an interrupting one and the release starts at once; after the run,
    /// every trigger retries a release that is still pending.
    func trigger(_ name: String) {
        guard !released else { return }
        if name == "teardown" { tornDown = true }
        let interrupts = Self.interrupting.contains(name)
        if !runEnded {
            guard interrupts else { return }
            if triggered == nil { triggered = name }
        }
        // task-owner: one bounded release round (about 4.5 s at most), joined by a round already running
        // main-hop-allow: a trigger's release is not frame work: one pointer-leave per send, at most 9 sends a round
        Task { @MainActor in await self.release(name, fresh: Self.fresh.contains(name)) }
    }

    /// Its view moved to another window or out of every one (``AgentPaneView/viewDidMoveToWindow()``).
    func viewMoved(inWindow: Bool) {
        trigger(inWindow ? "window" : "detached")
    }

    /// Gives the hover back: one bounded round of sends, or the round already running. With `fresh` (a
    /// trigger in ``fresh``), a round already running that ends without the release is followed by a new one.
    func release(_ reason: String, fresh: Bool = false) async {
        guard !released else { return }
        if let round {
            await round.value
            // That round's sends came before this event; one after it can now go in.
            guard fresh else { return }
            return await release(reason)
        }
        // The round clears itself as it ends, so a release asked for after it starts the next one.
        // main-hop-allow: its own task so a cancelled call can't cut the round short; one pointer-leave per send, at most 9
        let attempt = Task { @MainActor in
            await self.retry(reason)
            self.round = nil
        }
        round = attempt
        await attempt.value
    }

    /// One round: a send, and after each failed one a wait from ``retryWaits`` and another send.
    private func retry(_ reason: String) async {
        for wait in [Duration.zero] + Self.retryWaits {
            // wakeup-allow: the spacing after a failed send (50 ms doubling to 1 s, 8 in a round, about 4.5 s); the
            // event that can make it succeed (the view back in a window, the tab closing) starts the next round
            if wait > .zero { await sleep(wait) }
            guard !released else { return }
            // Nothing was moved: the page's hover is already the person's pointer's.
            guard armed else { return finish(tornDown ? "teardown" : reason) }
            sends += 1
            switch await send() {
            case .wentIn: return finish(tornDown ? "teardown" : reason)
            case .gone: return finish("teardown")
            case .failed: if tornDown { return finish("teardown") }
            }
        }
    }

    private func finish(_ reason: String) {
        released = true
        how = reason
        backstop?.cancel()
        backstop = nil
        view?.heldDrives[ObjectIdentifier(self)] = nil
    }
}

/// The window and the app a run drives in, read with the person (at most 100 ms apart, and before
/// each wheel tick): what outside the run ended it. No observer: a run reads them while it goes.
@MainActor
struct DriveSurroundings {
    /// The view's window now.
    let windowNow: @MainActor () -> NSWindow?
    /// The window the run started in.
    let window: NSWindow
    let isVisible: @MainActor () -> Bool
    let isActive: @MainActor () -> Bool
    /// The app was active when the run started: only a resign after that is one.
    let wasActive: Bool

    init(windowNow: @escaping @MainActor () -> NSWindow?, window: NSWindow, isVisible: @escaping @MainActor () -> Bool,
         isActive: @escaping @MainActor () -> Bool) {
        self.windowNow = windowNow
        self.window = window
        self.isVisible = isVisible
        self.isActive = isActive
        wasActive = isActive()
    }

    init(view: AgentPaneView, window: NSWindow) {
        self.init(windowNow: { [weak view] in view?.window }, window: window, isVisible: { [weak window] in window?.isVisible == true },
                  isActive: { NSApp.isActive })
    }

    /// `detached` (the view left every window), `window_close` (it is in another window now, or its
    /// window closed or is no longer shown), `resign` (the app was active and is not), or nil.
    func trigger() -> String? {
        guard let now = windowNow() else { return "detached" }
        if now !== window || !isVisible() { return "window_close" }
        if wasActive, !isActive() { return "resign" }
        return nil
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
