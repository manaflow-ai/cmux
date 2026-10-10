import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextTerminal
import os

/// Owns a window's keys from the moment a pane or terminal tab creation is handled (a split, New
/// Terminal Tab) until the new terminal has the keyboard (cx-wb5.76). Without it, keys typed
/// right after Cmd-D or Ctrl-` went to the old pane or tab: focus moves to the new one only after
/// the reply, and the optimistic split's swap to the daemon's pane remounts its view.
///
/// Every key-down of the window waits here, in order. The hold always ends on a lifecycle event,
/// never on a timer:
/// - every creation resolved (reply, failure or cancellation: the request timeout bounds it),
///   the focus each successful one asked for landed or was replaced, and the focused terminal's
///   view has the keyboard: the keys run again, as typed;
/// - the window shows another workspace: the hold stops waiting for its creations and its keys
///   go to the terminal that has focus there, once that terminal's view has the keyboard;
/// - a click in the window that the creation did not start, another window becoming key, or a
///   key typed into another window (a held key cannot move focus itself, so these are the focus
///   changes the creation did not cause): the keys go at once to the terminal that has focus in
///   their window.
/// - a creation whose pane is gone: once the store applied every event the daemon sent before the
///   creation's reply and holds no tab with the new surface, the creation counts as failed.
/// Held keys always go to the window they were typed in. They are dropped only when focus there
/// is on no terminal, with one log line (the count, never the keys).
@MainActor
final class CreationInputCoordinator {
    weak var router: KeyRouter?
    private var buffers: [Int: CreationInputBuffer] = [:]
    /// Set while a held key runs again, so it is not held a second time.
    private var replaying = false
    /// Set while AppKit dispatches a mouse-down: a creation it starts (a menu item, a button)
    /// keeps its hold through that click.
    private var dispatchingClick = false
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.input")
    private var keyObserver: (any NSObjectProtocol)?
    #if DEBUG
    /// Debug socket (`debug.creation_hold`) seams: the next split fails before it is sent; the
    /// next resolutions wait for an explicit release, so a proof can end a hold another way first.
    var failNextCreation = false
    var vanishNextCreation = false
    var ignoreNextPageAnswer = false
    var pausesResolutions = false
    private var pausedResolutions: [(CreationInputBuffer.Ticket, Bool, NSWindow)] = []
    #endif

    init(router: KeyRouter) {
        self.router = router
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                                             queue: .main) { [weak self] note in
            let number = (note.object as? NSWindow)?.windowNumber
            MainActor.assumeIsolated { self?.windowBecameKey(number) } // main-proof: observer on queue: .main
        }
    }

    /// Opens the window's hold for one creation that moves focus under the user intent
    /// `generation`; nil without a window, or when the creation may not move focus (a CLI,
    /// script or agent run without `focus`), which leaves the keys where they are.
    func begin(in window: NSWindow?, generation: UInt64?) -> CreationInputBuffer.Ticket? {
        guard let window, let generation, ActionRunScope.viewChangeAllowed(), let router,
              let content = router.focus(for: window).0?.content else { return nil }
        // An ended hold still waiting for a view gives its keys up first: the new hold starts clean.
        if buffers[window.windowNumber]?.isEnded == true { finish(in: window) }
        let buffer = buffers[window.windowNumber] ?? CreationInputBuffer(content: content)
        buffers[window.windowNumber] = buffer
        return buffer.open(generation: generation, duringClick: dispatchingClick)
    }

    /// The creation behind `ticket` got its reply (`landed`: its focus was asked for), failed or
    /// was cancelled. The keys go on in a new main-actor turn: outside the creation's task (its
    /// action scope) and after the focus events the reply queued.
    func resolve(_ ticket: CreationInputBuffer.Ticket?, landed: Bool, in window: NSWindow?) {
        #if DEBUG
        if pausesResolutions, let ticket, let window {
            pausedResolutions.append((ticket, landed, window))
            return
        }
        #endif
        guard let ticket, let window, let buffer = buffers[window.windowNumber], buffer.resolve(ticket, awaitsFocus: landed) else {
            return
        }
        scheduleFlush(in: window)
    }

    /// The creation behind `ticket` replied with `surface`: once `store` applied every event up to
    /// `sequence` (the write barrier taken after the reply), a store without that surface's tab
    /// means the pane is gone before it showed, so the hold stops waiting for its focus.
    func confirm(_ ticket: CreationInputBuffer.Ticket?, surface: SurfaceID, store: DaemonStore, sequence: UInt64?,
                 in window: NSWindow?) {
        guard let ticket, let window else { return }
        let target = surface
        store.whenApplied(.generate(), reaching: sequence) { [weak self, weak store, weak window] in
            // task-owner: one check in a fresh main-actor turn, after the ticket's resolution
            Task.detached { @MainActor [weak self, weak store, weak window] in
                guard let self, let store, let window, store.tab(surface: target) == nil,
                      let buffer = buffers[window.windowNumber], buffer.stopAwaiting(ticket) else { return }
                flush(in: window)
            }
        }
    }

    /// Holds `event` while a creation in its window is pending (or its ended hold waits for the
    /// focused terminal's view). A key typed into another window first ends the other windows'
    /// holds (the user switched windows), so their keys go before it.
    func capture(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard !replaying, let router, let window else { return false }
        let (controller, kind) = router.focus(for: window)
        guard kind == .content, let controller else { return false }
        let shell = controller.window ?? window
        finishHolds(except: shell.windowNumber, reason: "window switch")
        guard let buffer = buffers[shell.windowNumber] else { return false }
        if !buffer.isEnded, movedOn(buffer, controller: controller) {
            buffer.end(reason: "workspace switch")
            flush(in: shell)
            guard buffers[shell.windowNumber] === buffer else { return false }
        }
        buffer.capture(event)
        return true
    }

    /// A focus settle in `window`. Runs inside the focus coordinator's send, so it never replays
    /// here (a replayed key's focus events would wait in that queue): it marks a workspace switch
    /// and checks again in a new turn.
    func focusDidSettle(in window: NSWindow?) {
        guard let window, let buffer = buffers[window.windowNumber] else { return }
        if !buffer.isEnded, let controller = router?.focus(for: window).0, movedOn(buffer, controller: controller) {
            buffer.end(reason: "workspace switch")
        }
        scheduleFlush(in: window)
    }

    /// A mouse-down is about to be dispatched.
    func mouseDownWillDispatch() { dispatchingClick = true }

    /// A click in `window`, after AppKit moved focus to what was clicked: its hold ends there,
    /// unless the click itself started the hold's creation (a menu item, a button).
    func mouseDown(in window: NSWindow?) {
        dispatchingClick = false
        guard let window else { return }
        let shell = router?.focus(for: window).0?.window ?? window
        finishHolds(except: shell.windowNumber, reason: "window switch")
        guard let buffer = buffers[shell.windowNumber] else { return }
        if buffer.takeOpenedDuringClick() { return }
        buffer.end(reason: "click")
        finish(in: shell)
    }

    /// The window shows another workspace than when the hold began.
    private func movedOn(_ buffer: CreationInputBuffer, controller: WindowController) -> Bool {
        controller.content !== buffer.content
    }

    /// Another window became key: every other window's hold ends (in a new turn: the notification
    /// can come from inside a focus effect).
    private func windowBecameKey(_ number: Int?) {
        for held in Array(buffers.keys) where held != number {
            buffers[held]?.end(reason: "window switch")
            guard let window = NSApp.window(withWindowNumber: held) else {
                dropHeld(held, reason: "window closed")
                continue
            }
            // task-owner: one final flush of an ended hold in a fresh main-actor turn
            Task.detached { @MainActor [weak self, weak window] in
                guard let self, let window else { return }
                finish(in: window)
            }
        }
    }

    private func finishHolds(except number: Int, reason: String) {
        for held in Array(buffers.keys) where held != number {
            buffers[held]?.end(reason: reason)
            guard let window = NSApp.window(withWindowNumber: held) else {
                dropHeld(held, reason: "window closed")
                continue
            }
            finish(in: window)
        }
    }

    private func scheduleFlush(in window: NSWindow) {
        // task-owner: one flush check in a fresh main-actor turn, without the creating action's task-locals
        Task.detached { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            flush(in: window)
        }
    }

    private func flush(in window: NSWindow) {
        guard let buffer = buffers[window.windowNumber] else { return }
        guard let router, let controller = router.focus(for: window).0 else {
            return dropHeld(window.windowNumber, reason: "window closed")
        }
        if !buffer.isEnded, movedOn(buffer, controller: controller) { buffer.end(reason: "workspace switch") }
        guard buffer.isEnded else {
            // The normal end: every creation resolved and the focus it asked for landed.
            guard buffer.isResolved else { return }
            if let expectation = controller.focus.state.expectation, buffer.awaits(expectation.generation) { return }
            guard Self.responderTakesKeys(controller, window: window) else { return }
            return replay(window)
        }
        switch Self.focusedTerminal(controller, window: window) {
        case .ready: replay(window)
        case .waiting: return
        case .none: dropHeld(window.windowNumber, reason: buffer.endReason ?? "ended")
        }
    }

    /// The final end of an ended hold (a click, a window switch, a new hold): the keys go to the
    /// terminal that has focus in the window now, or to the terminal view that is first responder
    /// when focus is still settling; with neither, they are dropped (count logged).
    private func finish(in window: NSWindow) {
        guard let buffer = buffers[window.windowNumber] else { return }
        buffer.end(reason: "ended")
        guard let controller = router?.focus(for: window).0 else { return dropHeld(window.windowNumber, reason: "window closed") }
        switch Self.focusedTerminal(controller, window: window) {
        case .ready: replay(window)
        case .waiting where window.firstResponder is TerminalSurfaceView: replay(window)
        case .waiting, .none: dropHeld(window.windowNumber, reason: buffer.endReason ?? "ended")
        }
    }

    private func dropHeld(_ number: Int, reason: String) {
        guard let buffer = buffers.removeValue(forKey: number) else { return }
        let count = buffer.take().count
        if count > 0 { logger.info("dropped \(count, privacy: .public) held keys (\(reason, privacy: .public)): no terminal takes them") }
    }

    /// Runs the held keys again in their own window, as typed: through the whole app dispatch
    /// (key router, key equivalents, menu) when that window takes keys now, else through the key
    /// router and the window's key equivalents and responder.
    private func replay(_ window: NSWindow) {
        let number = window.windowNumber
        guard let buffer = buffers.removeValue(forKey: number) else { return }
        let pending = buffer.take()
        for (index, event) in pending.enumerated() {
            replaying = true
            if NSApp.keyWindow == nil || NSApp.keyWindow === window {
                NSApp.sendEvent(event)
            } else if let router, !router.interceptKeyDown(event, in: window), !window.performKeyEquivalent(with: event) {
                window.sendEvent(event)
            }
            replaying = false
            // A replayed key started another creation: the rest wait for that one, in order.
            if let next = buffers[number] {
                next.prepend(pending.dropFirst(index + 1))
                return
            }
        }
    }

    /// Debug socket: the windows with a hold and their held key counts.
    var heldKeyCounts: [Int: Int] { buffers.mapValues(\.count) }

    #if DEBUG
    /// Debug socket: the next split's focus and pane check name a surface that never exists, as
    /// when its pane is gone before its echo (consumed once). Returns the surface to use.
    func vanishingSurface(_ surface: SurfaceID) -> SurfaceID {
        guard vanishNextCreation else { return surface }
        vanishNextCreation = false
        return SurfaceID(rawValue: 0)
    }

    /// Debug socket: the next New Tab page focus hold ignores the page's answer, as when the page
    /// crashed (consumed once); `debug.creation_hold {"page_gone": true}` then ends it.
    func takeIgnorePageAnswer() -> Bool {
        defer { ignoreNextPageAnswer = false }
        return ignoreNextPageAnswer
    }

    /// Debug socket: the split behind the next ticket fails (consumed once).
    func takeInjectedFailure() -> Bool {
        defer { failNextCreation = false }
        return failNextCreation
    }

    /// Debug socket: stops pausing and applies the paused resolutions in order.
    func releasePausedResolutions() {
        pausesResolutions = false
        let paused = pausedResolutions
        pausedResolutions = []
        for (ticket, landed, window) in paused { resolve(ticket, landed: landed, in: window) }
    }
    #endif
}

extension CreationInputCoordinator {
    enum TerminalReadiness { case ready, waiting, none }

    /// The terminal that has focus in `window` now: `ready` when its view is the first responder,
    /// `waiting` while it is not yet (a remount or a workspace swap in progress), `none` when focus
    /// is on no terminal that can take keys (a page, the sidebar, a terminal not attached).
    static func focusedTerminal(_ controller: WindowController, window: NSWindow) -> TerminalReadiness {
        guard case .terminal(let pane, let tab) = controller.focus.state.resolved,
              let paneController = controller.content?.paneController(key: pane), paneController.currentTabKey == tab,
              case .terminal(let entry)? = paneController.currentContent else { return .none }
        guard let responder = window.firstResponder as? NSView else { return .waiting }
        return responder === entry.session.surfaceView || responder.isDescendant(of: entry.session.view) ? .ready : .waiting
    }

    /// False while focus names a shown terminal whose view does not have the keyboard and the
    /// window's first responder is another terminal or the window itself (a remounted view):
    /// a key now would land in the wrong terminal or nowhere. Anything else takes the keys.
    static func responderTakesKeys(_ controller: WindowController, window: NSWindow) -> Bool {
        guard case .terminal(let pane, let tab) = controller.focus.state.resolved,
              let paneController = controller.content?.paneController(key: pane), paneController.currentTabKey == tab,
              case .terminal(let entry)? = paneController.currentContent else { return true }
        guard let responder = window.firstResponder as? NSView else { return false }
        if responder === entry.session.surfaceView || responder.isDescendant(of: entry.session.view) { return true }
        return !(responder is TerminalSurfaceView)
    }
}

/// The keys of one window's pending creations, in typing order.
@MainActor
final class CreationInputBuffer {
    struct Ticket: Hashable {
        fileprivate let hold: UInt64
        fileprivate let id: Int
        fileprivate let generation: UInt64
    }

    /// Hold numbers never repeat in a process, so a late resolution of an ended hold matches nothing.
    private static var nextHold: UInt64 = 0
    private let hold: UInt64
    /// The workspace shown when the hold began; another one ends it.
    weak var content: WorkspaceContentController?
    private var events: [NSEvent] = []
    private var pending: [Int: UInt64] = [:]
    private var awaited: Set<UInt64> = []
    private var nextID = 0
    private var openedDuringClick = false
    /// Ended early (a click, a workspace or window switch): it waits for no creation any more.
    private(set) var endReason: String?

    init(content: WorkspaceContentController) {
        Self.nextHold &+= 1
        hold = Self.nextHold
        self.content = content
    }

    var isResolved: Bool { pending.isEmpty }
    var isEnded: Bool { endReason != nil }
    var count: Int { events.count }

    func end(reason: String) { if endReason == nil { endReason = reason } }

    func open(generation: UInt64, duringClick: Bool) -> Ticket {
        nextID += 1
        pending[nextID] = generation
        if duringClick { openedDuringClick = true }
        return Ticket(hold: hold, id: nextID, generation: generation)
    }

    /// Whether a creation of this hold started during the click being dispatched (then that click
    /// does not end it); clears the mark.
    func takeOpenedDuringClick() -> Bool {
        defer { openedDuringClick = false }
        return openedDuringClick
    }

    /// `awaitsFocus`: the creation asked for focus under its generation; the keys wait until that
    /// expectation landed or was replaced. A failed creation asked for nothing. False for a ticket
    /// of another (ended) hold.
    func resolve(_ ticket: Ticket, awaitsFocus: Bool) -> Bool {
        guard ticket.hold == hold, let generation = pending.removeValue(forKey: ticket.id) else { return false }
        if awaitsFocus { awaited.insert(generation) }
        return true
    }

    func awaits(_ generation: UInt64) -> Bool { awaited.contains(generation) }

    /// The creation behind `ticket` is gone: the hold no longer waits for its focus. False for a
    /// ticket of another hold or one not resolved yet.
    func stopAwaiting(_ ticket: Ticket) -> Bool {
        guard ticket.hold == hold, pending[ticket.id] == nil else { return false }
        return awaited.remove(ticket.generation) != nil
    }

    func capture(_ event: NSEvent) { events.append(event) }

    func prepend(_ earlier: ArraySlice<NSEvent>) { events.insert(contentsOf: earlier, at: 0) }

    func take() -> [NSEvent] {
        defer { events.removeAll() }
        return events
    }
}
