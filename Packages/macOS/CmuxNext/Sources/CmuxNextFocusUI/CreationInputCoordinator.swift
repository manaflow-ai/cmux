public import AppKit
import CmuxNextActions
import os

/// What a creation hold reads from the window a key is for: the App's focus and views (`KeyRouter` provides it).
public struct CreationInputFocus {
    /// The window whose number keys the hold: the key's cmux window (a Chromium page window's shell). Nil when no
    /// cmux window shows the key's window (it closed).
    public var shell: NSWindow?
    /// The key goes to the window's content, not a sidebar, bar or panel field.
    public var inContent: Bool
    /// The tab a focus expectation of the window waits for, and the generation of any expectation it has.
    public var expectedTab: String?
    public var expectedGeneration: UInt64?
    /// The terminal tab the window's focus names; nil when it names none.
    public var terminalTab: String?
    /// A key now lands where the focus names (``CreationInputHost`` decides: never in another terminal or nowhere).
    public var takesKeys: Bool
    /// ``terminalTab`` is shown in its pane and its terminal view is the window's first responder: only then may a
    /// pending creation's early view take held keys (never another terminal, an agent's composer or a message box).
    public var terminalHasKeyboard: Bool
    /// ``terminalTab`` is the tab its pane shows now (its view is mounted there).
    public var terminalShown: Bool

    public init(shell: NSWindow?, inContent: Bool, expectedTab: String? = nil, expectedGeneration: UInt64? = nil,
                terminalTab: String? = nil, takesKeys: Bool = true, terminalHasKeyboard: Bool = false, terminalShown: Bool = false) {
        (self.shell, self.inContent, self.expectedTab, self.expectedGeneration) = (shell, inContent, expectedTab, expectedGeneration)
        (self.terminalTab, self.takesKeys, self.terminalHasKeyboard, self.terminalShown) = (terminalTab, takesKeys, terminalHasKeyboard, terminalShown)
    }
}

/// The App side of the creation holds: the focus of a window, its close keys, and where held keys run again.
@MainActor
public protocol CreationInputHost: AnyObject {
    /// The cmux window `window` belongs to (a Chromium page window's shell), nil when none: a lookup only, run for
    /// every key-down before anything else, so a window with no hold pays nothing more.
    func creationShell(of window: NSWindow) -> NSWindow?
    /// The focus of the cmux window `window` belongs to, read when a hold decides a key or its end.
    func creationFocus(in window: NSWindow) -> CreationInputFocus
    /// Whether `event`'s binding in `shell`'s focus is a close action (Close Tab, Cmd-W).
    func isCloseKey(_ event: NSEvent, in shell: NSWindow) -> Bool
    /// Runs held key `event` again, as typed in `window` (the app: `NSApp.sendEvent`, to the key window).
    func replayHeldKey(_ event: NSEvent, in window: NSWindow)
    /// A focus settled: keys the daemon gave back go to the focused terminal of their window.
    func deliverGivenBack()
    /// The action the last key ran, for the bound's log line.
    var lastKeyAction: String? { get }
}

/// Owns a window's keys from the moment a pane or terminal tab creation is handled (a split, New
/// Terminal Tab) until the new terminal has the keyboard (cx-wb5.76). Without it, keys typed
/// right after Cmd-D or Ctrl-` went to the old pane or tab: focus moves to the new one only after
/// the reply, and the optimistic split's swap to the daemon's pane remounts its view. Every
/// key-down of the window waits here, in order, until each creation resolved (its reply, or its
/// failure: the request timeout is the only bound), the focus each one asked for landed or was
/// replaced, and the focused terminal's view has the keyboard; then the keys run again through
/// the host (`NSApplication.sendEvent` in the app), as typed (the key router, key equivalents and the menu included).
///
/// The same hold covers Ctrl-1…9 onto a terminal tab with no surface yet (hq#1925 item 3; bound
/// in `CreationInputBuffer.holds`). Any hold ends as soon as focus leaves the content (cx-wb5.78: `earlyTab`).
@MainActor
public final class CreationInputCoordinator {
    public weak var host: (any CreationInputHost)?
    private var buffers: [Int: CreationInputBuffer] = [:]
    /// Set while a captured key runs again, so it is not captured a second time.
    private var replaying = false
    /// Held keys run again since launch (tests: a key must never be run into a view it was not typed for).
    private(set) var replayedCount = 0
    /// The longest a key waits for a selected terminal's surface (the slowest takes about 350 ms).
    public var holdLimit: Duration = .seconds(2)

    /// Windows whose current hold had a creation that failed: its unforced end is ``CreationHoldEnd/creationFailed``.
    private var failedCreation: Set<Int> = []

    /// How the last creation hold of each window ended, by window number (tests, `debug.focus`).
    public private(set) var lastHoldEnd: [Int: CreationHoldEnd] = [:]

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "focus.creation-hold")

    public init() {}

    /// How `window`'s last creation hold ended; nil when it never held.
    public func lastHoldEnd(in window: NSWindow?) -> CreationHoldEnd? { window.flatMap { lastHoldEnd[$0.windowNumber] } }

    /// Whether `window`'s keys wait in a creation hold now (tests: a key typed meanwhile is replayed later).
    public func isHolding(in window: NSWindow?) -> Bool { window.map { buffers[$0.windowNumber] != nil } ?? false }

    /// How many keys `window`'s hold keeps now (tests).
    func heldCount(in window: NSWindow?) -> Int { window.flatMap { buffers[$0.windowNumber] }?.count ?? 0 }

    /// Why `window`'s held keys would or would not go to a pending creation's early view now (tests' failure reports).
    func earlyDeliveryState(in window: NSWindow) -> String {
        guard let buffer = buffers[window.windowNumber] else { return "no hold" }
        guard let focus = host?.creationFocus(in: window), focus.shell != nil else { return "no window" }
        return "resolved \(buffer.isResolved), held \(buffer.count), newestEarlyTab \(buffer.newestEarlyTab ?? "-"), "
            + "focus terminal \(focus.terminalTab ?? "-"), has keyboard \(focus.terminalHasKeyboard), takesKeysEarly \(Self.takesKeysEarly(buffer, focus))"
    }

    /// Opens the window's buffer for one creation that moves focus under the user intent
    /// `generation`; nil without a window, or when the creation may not move focus (a CLI,
    /// script or agent run without `focus`), which leaves the keys where they are.
    public func begin(in window: NSWindow?, generation: UInt64?, earlyTab: String? = nil, tab: String? = nil) -> CreationInputBuffer.Ticket? {
        guard let window, let generation, ActionRunScope.viewChangeAllowed() else { return nil }
        return buffer(in: window).open(generation: generation, earlyTab: earlyTab, tab: tab)
    }

    /// A creation's placement continues after its create reply (Home moves the new terminal beside
    /// its dock). Open the placement's ticket before the creator resolves its own, so held keys
    /// cannot run into the old terminal during the move. A move without a creation adds no hold.
    public func continueCreation(in window: NSWindow?, generation: UInt64?) -> CreationInputBuffer.Ticket? {
        guard hasPendingCreation(in: window) else { return nil }
        return begin(in: window, generation: generation)
    }

    /// Whether a creation or its asynchronous placement is still outstanding in this window.
    public func hasPendingCreation(in window: NSWindow?) -> Bool { window.flatMap { buffers[$0.windowNumber] }?.hasPendingCreation == true }

    /// The person closed provisional tab `tab` in `window` before the daemon made it: the keys held
    /// for it are dropped and the rest go on (``CreationInputBuffer/cancel(tab:)``).
    public func drop(tab: String, in window: NSWindow?) {
        if let window, buffers[window.windowNumber]?.cancel(tab: tab) == true { scheduleFlush(in: window) }
    }

    /// A selection shows a terminal whose surface comes later: keys wait for it, at most `holdLimit`.
    public func holdUntilShown(in window: NSWindow?) {
        guard let window, ActionRunScope.viewChangeAllowed() else { return }
        _ = buffer(in: window)
    }

    private func buffer(in window: NSWindow) -> CreationInputBuffer {
        let number = window.windowNumber
        if let buffer = buffers[number] { return buffer }
        let buffer = CreationInputBuffer(began: ContinuousClock.now)
        buffers[number] = buffer
        expire(buffer, in: window)
        return buffer
    }

    /// Ends `buffer`'s hold `holdLimit` from now, unless a creation of it still waits for its reply then.
    private func expire(_ buffer: CreationInputBuffer, in window: NSWindow) {
        let number = window.windowNumber
        buffer.expire(after: holdLimit) { [weak self, weak window] buffer in
            guard let self, buffers[number] === buffer else { return }
            if let window { flush(in: window, force: true, end: .limitReached) } else { buffers[number] = nil }
        }
    }

    /// The creation behind `ticket` got its reply (`landed`: its focus was asked for) or failed.
    /// The keys go on in a new main-actor turn: outside the creation's task (its action scope)
    /// and after the focus events the reply queued.
    public func resolve(_ ticket: CreationInputBuffer.Ticket?, landed: Bool, in window: NSWindow?) {
        guard let ticket, let window, let buffer = buffers[window.windowNumber] else { return }
        if !landed { failedCreation.insert(window.windowNumber) }
        buffer.resolve(ticket, awaitsFocus: landed)
        scheduleFlush(in: window)
        // The focus it asked for may never land (a split from a page tab shows a New Tab page):
        // the keys go on `holdLimit` after the reply at the latest.
        expire(buffer, in: window)
    }

    /// Takes `event` while a creation in its window is pending.
    public func capture(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard !replaying, let host, let window else { return false }
        // A Chromium page window is a child of the shell, whose number keys the buffer. Every key-down of the process
        // comes here (KeyRouter.interceptKeyDown, perf-hot): with no hold, only this lookup runs, as before the move.
        let shell = host.creationShell(of: window) ?? window
        guard let buffer = buffers[shell.windowNumber] else { return false }
        let focus = host.creationFocus(in: window)
        // A close key (Cmd-W) acts now on what it closes; held, it ran later with the other keys.
        let closes = focus.shell != nil && host.isCloseKey(event, in: shell)
        // A close of a pending creation of this hold (the focus it asked for is on its way, or already
        // landed on it before the reply): the keys typed for it go with it, the others keep waiting in
        // order, and the close runs now (TabLifecycle cancels the creation). Nothing is run into whatever
        // has the focus first.
        if closes, let tab = Self.creatingTab(focus, in: buffer) {
            _ = buffer.cancel(tab: tab)
            scheduleFlush(in: shell)
            return false
        }
        // Focus left the content (a sidebar or bar field) or the hold lets this key go: the held
        // keys go on first, then this one (into a hold a replayed key opened, if it keeps it).
        guard focus.inContent, focus.shell != nil, buffer.holds(event, limit: holdLimit, expiring: true, closes: closes) else {
            flush(in: shell, force: true, end: .focusLeft)
            guard let next = buffers[shell.windowNumber], next.holds(event, limit: holdLimit, expiring: false, closes: closes) else { return false }
            next.capture(event)
            return true
        }
        // Every creation replied and what they asked for holds now (focus landed, the new terminal has the keyboard):
        // the hold ends at this key, its held keys first, then this one goes on. A settle is not waited for: none may
        // come after the terminal took the keyboard, and the keys then waited for the hold's 2 s bound.
        if buffer.isResolved {
            flush(in: shell, atKey: true)
            guard let next = buffers[shell.windowNumber] else { return false }
            guard next === buffer else {
                // A held key run again started another hold: this one waits in it, in order, if that hold keeps it (a
                // chord passes an empty surface hold, as on the forced path above).
                guard next.holds(event, limit: holdLimit, expiring: false, closes: closes) else { return false }
                next.capture(event)
                return true
            }
        }
        // A pending creation's early view has the keyboard: held keys first, then this one.
        if Self.takesKeysEarly(buffer, host.creationFocus(in: shell)) {
            guard deliverEarly(buffer, in: shell) else {
                // A key run again started another creation: this one waits for it, in order, if the hold keeps it.
                guard buffer.holds(event, limit: holdLimit, expiring: false, closes: closes) else { return false }
                buffer.capture(event)
                return true
            }
            return false
        }
        buffer.capture(event)
        return true
    }

    /// The pending creation of `buffer` that the focus asks for (its expectation) or already names (focus landed on
    /// it before the reply): a close key then closes it, and the keys typed for it go with it.
    private static func creatingTab(_ focus: CreationInputFocus, in buffer: CreationInputBuffer) -> String? {
        if let tab = focus.expectedTab, buffer.isCreating(tab: tab) { return tab }
        if let tab = focus.terminalTab, buffer.isCreating(tab: tab) { return tab }
        return nil
    }

    /// Whether a pending creation's early view (its terminal, which sends keys to the daemon by the terminal id the
    /// create chose, cx-wb5.78) is the focused terminal and has the keyboard: keys go to it now, not after the reply.
    /// Only that view: the focus names the newest pending creation's early tab, and that terminal has the keyboard.
    private static func takesKeysEarly(_ buffer: CreationInputBuffer, _ focus: CreationInputFocus) -> Bool {
        guard let tab = focus.terminalTab, buffer.newestEarlyTab == tab else { return false }
        return focus.terminalHasKeyboard
    }

    /// Runs the held keys into the early view that has the keyboard, in order, at once. False when a key run again
    /// started another creation: the rest wait for it, in order.
    /// A replayed key may also take the keyboard away from that view (Ctrl-1…9 or Ctrl-Tab onto another tab, whose
    /// surface hold reuses this buffer and opens no creation): the rest, and the key being judged, then keep waiting.
    private func deliverEarly(_ buffer: CreationInputBuffer, in window: NSWindow) -> Bool {
        guard let host else { return true }
        let opened = buffer.openedCount
        let stopping = { buffer.openedCount != opened || !Self.takesKeysEarly(buffer, host.creationFocus(in: window)) }
        guard let rest = replay(buffer.take(), in: window, host: host, stopping: stopping) else { return true }
        buffer.prepend(rest)
        return false
    }

    /// Runs `events` again through the host, in typing order; stops after a key once `stopping()` holds (it started
    /// another creation) and returns the keys not run. Nil when every key ran.
    private func replay(_ events: [NSEvent], in window: NSWindow, host: any CreationInputHost,
                        stopping: () -> Bool) -> ArraySlice<NSEvent>? {
        for (index, event) in events.enumerated() {
            replaying = true
            replayedCount += 1
            host.replayHeldKey(event, in: window)
            replaying = false
            if stopping() { return events.dropFirst(index + 1) }
        }
        return nil
    }

    /// A focus settle in `window`: the keys may go on (in a new turn, after the focus queue).
    public func focusDidSettle(in window: NSWindow?) {
        host?.deliverGivenBack()
        guard let window, buffers[window.windowNumber] != nil else { return }
        scheduleFlush(in: window)
    }

    private func scheduleFlush(in window: NSWindow) {
        // task-owner: one flush check in a fresh main-actor turn, without the creating action's task-locals
        Task.detached { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            flush(in: window)
        }
    }

    /// `force`: the hold ends now (its limit, focus left the content), whatever it waited for.
    /// `end`: why a forced end happened; an unforced one is ``CreationHoldEnd/focusLanded``.
    /// A pending creation whose early view got the keyboard takes the held keys now: the hold stays (later keys go
    /// straight to that view through ``capture(_:in:)``) until the creation resolves.
    /// `atKey`: a key, not a settle, ends the resolved hold (``capture(_:in:)``): only into the terminal the focus names.
    private func flush(in window: NSWindow, force: Bool = false, end forcedEnd: CreationHoldEnd = .limitReached, atKey: Bool = false) {
        guard let buffer = buffers[window.windowNumber] else { return }
        if !force, !buffer.isResolved {
            if !buffer.isEmpty, let host, Self.takesKeysEarly(buffer, host.creationFocus(in: window)) { _ = deliverEarly(buffer, in: window) }
            return
        }
        let focus = host?.creationFocus(in: window)
        guard let host, let focus, focus.shell != nil else {
            // The window is gone: its keys go with it.
            buffers[window.windowNumber] = nil
            failedCreation.remove(window.windowNumber)
            lastHoldEnd[window.windowNumber] = .windowClosed
            return
        }
        if !force {
            if let generation = focus.expectedGeneration, buffer.awaits(generation) { return }
            guard focus.takesKeys else { return }
            // A key ending a resolved hold (new; before, only a settle did): when the focus names a terminal that its
            // pane shows, that terminal must have the keyboard, never an agent's composer or a message box over it. A
            // settle ends the hold as before, so a settle into another view does not now wait for the hold's bound.
            if atKey, focus.terminalShown, !focus.terminalHasKeyboard { return }
        }
        buffers[window.windowNumber] = nil
        let failed = failedCreation.remove(window.windowNumber) != nil
        let end = force ? forcedEnd : failed ? .creationFailed : .focusLanded
        lastHoldEnd[window.windowNumber] = end
        let pending = buffer.take()
        if end == .limitReached {
            // The person's keys for a new terminal waited the whole bound and go on now, into whatever has the focus.
            Self.logger.notice("creation hold of window \(window.windowNumber, privacy: .public) ended at its limit, not on focus: \(pending.count, privacy: .public) held key(s) go on now; last action \(host.lastKeyAction ?? "-", privacy: .public)")
        }
        // A replayed key started another creation: the rest wait for that one, in order.
        if let rest = replay(pending, in: window, host: host, stopping: { buffers[window.windowNumber] != nil }) {
            buffers[window.windowNumber]?.prepend(rest)
        }
    }
}
