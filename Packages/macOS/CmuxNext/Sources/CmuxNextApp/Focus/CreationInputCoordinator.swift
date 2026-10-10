import AppKit
import CmuxNextActions
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
///   view has the keyboard: the keys run again through `NSApplication.sendEvent`, as typed;
/// - a click in the window, the window showing another workspace, another window becoming key or
///   a key typed into another window: the hold stops waiting for its creations, and its keys run
///   again into the terminal that has focus now, as soon as that terminal's view has the keyboard
///   (a held key cannot move focus itself, so these are the focus changes the creation did not
///   cause).
/// Keys are dropped only when no terminal has focus then, with one log line (the count, never the
/// keys).
@MainActor
final class CreationInputCoordinator {
    weak var router: KeyRouter?
    private var buffers: [Int: CreationInputBuffer] = [:]
    /// Set while a held key runs again, so it is not held a second time.
    private var replaying = false
    /// Debug socket (`debug.creation_hold`) seams: the next split fails before it is sent; the
    /// next resolutions wait for an explicit release, so a proof can end a hold another way first.
    var failNextCreation = false
    var pausesResolutions = false
    private var pausedResolutions: [(CreationInputBuffer.Ticket, Bool, NSWindow)] = []
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.input")
    private var keyObserver: (any NSObjectProtocol)?

    init(router: KeyRouter) {
        self.router = router
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                                             queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.windowBecameKey(window) } // main-proof: observer on queue: .main
        }
    }

    /// Opens the window's hold for one creation that moves focus under the user intent
    /// `generation`; nil without a window, or when the creation may not move focus (a CLI,
    /// script or agent run without `focus`), which leaves the keys where they are.
    func begin(in window: NSWindow?, generation: UInt64?) -> CreationInputBuffer.Ticket? {
        guard let window, let generation, ActionRunScope.viewChangeAllowed(), let router,
              let content = router.focus(for: window).0?.content else { return nil }
        let buffer = buffers[window.windowNumber] ?? CreationInputBuffer(content: content)
        buffers[window.windowNumber] = buffer
        return buffer.open(generation: generation)
    }

    /// The creation behind `ticket` got its reply (`landed`: its focus was asked for), failed or
    /// was cancelled. The keys go on in a new main-actor turn: outside the creation's task (its
    /// action scope) and after the focus events the reply queued.
    func resolve(_ ticket: CreationInputBuffer.Ticket?, landed: Bool, in window: NSWindow?) {
        if pausesResolutions, let ticket, let window {
            pausedResolutions.append((ticket, landed, window))
            return
        }
        guard let ticket, let window, let buffer = buffers[window.windowNumber], buffer.resolve(ticket, awaitsFocus: landed) else {
            return
        }
        scheduleFlush(in: window)
    }

    /// Holds `event` while a creation in its window is pending (or its ended hold waits for the
    /// focused terminal's view). A key typed into another window ends the holds of the other
    /// windows first (the user switched windows), so their keys go before it.
    func capture(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard !replaying, let router, let window else { return false }
        let (controller, kind) = router.focus(for: window)
        guard kind == .content, let controller else { return false }
        let shell = controller.window ?? window
        endHolds(except: shell.windowNumber, reason: "window switch")
        guard let buffer = buffers[shell.windowNumber] else { return false }
        if !buffer.isEnded, movedOn(buffer, controller: controller) {
            end(in: shell, reason: "workspace switch")
            guard buffers[shell.windowNumber] != nil else { return false }
        }
        buffer.capture(event)
        return true
    }

    /// A focus settle in `window`: a hold whose window shows another workspace ends now; any hold
    /// may go on (in a new turn, after the focus queue).
    func focusDidSettle(in window: NSWindow?) {
        guard let window, let buffer = buffers[window.windowNumber] else { return }
        if !buffer.isEnded, let controller = router?.focus(for: window).0, movedOn(buffer, controller: controller) {
            return end(in: window, reason: "workspace switch")
        }
        scheduleFlush(in: window)
    }

    /// A click in `window`, after AppKit moved focus to what was clicked: its hold ends there.
    func mouseDown(in window: NSWindow?) {
        guard let window else { return }
        let shell = router?.focus(for: window).0?.window ?? window
        endHolds(except: shell.windowNumber, reason: "window switch")
        guard buffers[shell.windowNumber] != nil else { return }
        end(in: shell, reason: "click")
    }

    /// The window shows another workspace than when the hold began.
    private func movedOn(_ buffer: CreationInputBuffer, controller: WindowController) -> Bool {
        controller.content !== buffer.content
    }

    /// Another window became key: every other window's hold ends.
    private func windowBecameKey(_ window: NSWindow?) {
        endHolds(except: window?.windowNumber, reason: "window switch")
    }

    private func endHolds(except number: Int?, reason: String) {
        for held in Array(buffers.keys) where held != number {
            guard let window = NSApp.window(withWindowNumber: held) else {
                dropHeld(held, reason: "window closed")
                continue
            }
            end(in: window, reason: reason)
        }
    }

    private func scheduleFlush(in window: NSWindow) {
        // task-owner: one flush check in a fresh main-actor turn, without the creating action's task-locals
        Task.detached { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            flush(in: window)
        }
    }

    /// An early end: the hold stops waiting for its creations; its keys go to the terminal that
    /// has focus now, once that terminal's view has the keyboard, or are dropped (count logged)
    /// when focus is on no terminal.
    private func end(in window: NSWindow, reason: String) {
        guard let buffer = buffers[window.windowNumber], !buffer.isEnded else { return }
        buffer.end(reason: reason)
        flush(in: window)
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
            return replay(window.windowNumber)
        }
        switch Self.focusedTerminal(controller, window: window) {
        case .ready: replay(window.windowNumber)
        case .waiting: return
        case .none: dropHeld(window.windowNumber, reason: buffer.endReason ?? "ended")
        }
    }

    private func dropHeld(_ number: Int, reason: String) {
        guard let buffer = buffers.removeValue(forKey: number) else { return }
        let count = buffer.take().count
        if count > 0 { logger.info("dropped \(count, privacy: .public) held keys: \(reason, privacy: .public), no terminal has focus") }
    }

    private func replay(_ number: Int) {
        guard let buffer = buffers.removeValue(forKey: number) else { return }
        let pending = buffer.take()
        for (index, event) in pending.enumerated() {
            replaying = true
            NSApp.sendEvent(event)
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
        fileprivate let buffer: ObjectIdentifier
        fileprivate let id: Int
    }

    /// The workspace shown when the hold began; another one ends it.
    weak var content: WorkspaceContentController?
    private var events: [NSEvent] = []
    private var pending: [Int: UInt64] = [:]
    private var awaited: Set<UInt64> = []
    private var nextID = 0

    init(content: WorkspaceContentController) { self.content = content }

    var isResolved: Bool { pending.isEmpty }
    /// Ended early (a click, a workspace or window switch): it waits for no creation any more.
    private(set) var endReason: String?
    var isEnded: Bool { endReason != nil }

    func end(reason: String) { if endReason == nil { endReason = reason } }
    var count: Int { events.count }

    func open(generation: UInt64) -> Ticket {
        nextID += 1
        pending[nextID] = generation
        return Ticket(buffer: ObjectIdentifier(self), id: nextID)
    }

    /// `awaitsFocus`: the creation asked for focus under its generation; the keys wait until that
    /// expectation landed or was replaced. A failed creation asked for nothing. False for a ticket
    /// of another (ended) hold.
    func resolve(_ ticket: Ticket, awaitsFocus: Bool) -> Bool {
        guard ticket.buffer == ObjectIdentifier(self), let generation = pending.removeValue(forKey: ticket.id) else { return false }
        if awaitsFocus { awaited.insert(generation) }
        return true
    }

    func awaits(_ generation: UInt64) -> Bool { awaited.contains(generation) }

    func capture(_ event: NSEvent) { events.append(event) }

    func prepend(_ earlier: ArraySlice<NSEvent>) { events.insert(contentsOf: earlier, at: 0) }

    func take() -> [NSEvent] {
        defer { events.removeAll() }
        return events
    }
}
