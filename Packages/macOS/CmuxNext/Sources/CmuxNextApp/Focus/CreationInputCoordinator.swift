import AppKit
import CmuxNextActions
import CmuxNextTerminal

/// Owns a window's keys from the moment a pane or terminal tab creation is handled (a split, New
/// Terminal Tab) until the new terminal has the keyboard (cx-wb5.76). Without it, keys typed
/// right after Cmd-D or Ctrl-` went to the old pane or tab: focus moves to the new one only after
/// the reply, and the optimistic split's swap to the daemon's pane remounts its view. Every
/// key-down of the window waits here, in order, until each creation resolved (its reply, or its
/// failure: the request timeout is the only bound), the focus each one asked for landed or was
/// replaced, and the focused terminal's view has the keyboard; then the keys run again through
/// `NSApplication.sendEvent`, as typed (the key router, key equivalents and the menu included).
@MainActor
final class CreationInputCoordinator {
    weak var router: KeyRouter?
    private var buffers: [Int: CreationInputBuffer] = [:]
    /// Set while a captured key runs again, so it is not captured a second time.
    private var replaying = false

    init(router: KeyRouter) { self.router = router }

    /// Opens the window's buffer for one creation that moves focus under the user intent
    /// `generation`; nil without a window, or when the creation may not move focus (a CLI,
    /// script or agent run without `focus`), which leaves the keys where they are.
    func begin(in window: NSWindow?, generation: UInt64?) -> CreationInputBuffer.Ticket? {
        guard let window, let generation, ActionRunScope.viewChangeAllowed() else { return nil }
        let buffer = buffers[window.windowNumber] ?? CreationInputBuffer()
        buffers[window.windowNumber] = buffer
        return buffer.open(generation: generation)
    }

    /// The creation behind `ticket` got its reply (`landed`: its focus was asked for) or failed.
    /// The keys go on in a new main-actor turn: outside the creation's task (its action scope)
    /// and after the focus events the reply queued.
    func resolve(_ ticket: CreationInputBuffer.Ticket?, landed: Bool, in window: NSWindow?) {
        guard let ticket, let window, let buffer = buffers[window.windowNumber] else { return }
        buffer.resolve(ticket, awaitsFocus: landed)
        scheduleFlush(in: window)
    }

    /// Takes `event` while a creation in its window is pending.
    func capture(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard !replaying, let router, let window else { return false }
        let (controller, kind) = router.focus(for: window)
        // A Chromium page window is a child of the shell, whose number keys the buffer.
        guard kind == .content, let controller else { return false }
        let shell = controller.window ?? window
        guard let buffer = buffers[shell.windowNumber] else { return false }
        buffer.capture(event)
        return true
    }

    /// A focus settle in `window`: the keys may go on (in a new turn, after the focus queue).
    func focusDidSettle(in window: NSWindow?) {
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

    private func flush(in window: NSWindow) {
        guard let buffer = buffers[window.windowNumber], buffer.isResolved else { return }
        guard let router, let controller = router.focus(for: window).0 else {
            // The window is gone: its keys go with it.
            buffers[window.windowNumber] = nil
            return
        }
        let focus = controller.focus.state
        if let expectation = focus.expectation, buffer.awaits(expectation.generation) { return }
        guard Self.responderTakesKeys(controller, window: window) else { return }
        buffers[window.windowNumber] = nil
        let pending = buffer.take()
        for (index, event) in pending.enumerated() {
            replaying = true
            NSApp.sendEvent(event)
            replaying = false
            // A replayed key started another creation: the rest wait for that one, in order.
            if let next = buffers[window.windowNumber] {
                next.prepend(pending.dropFirst(index + 1))
                return
            }
        }
    }
}

extension CreationInputCoordinator {
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
    struct Ticket: Hashable { fileprivate let id: Int }

    private var events: [NSEvent] = []
    private var pending: [Int: UInt64] = [:]
    private var awaited: Set<UInt64> = []
    private var nextID = 0

    var isResolved: Bool { pending.isEmpty }

    func open(generation: UInt64) -> Ticket {
        nextID += 1
        pending[nextID] = generation
        return Ticket(id: nextID)
    }

    /// `awaitsFocus`: the creation asked for focus under its generation; the keys wait until that
    /// expectation landed or was replaced. A failed creation asked for nothing.
    func resolve(_ ticket: Ticket, awaitsFocus: Bool) {
        guard let generation = pending.removeValue(forKey: ticket.id) else { return }
        if awaitsFocus { awaited.insert(generation) }
    }

    func awaits(_ generation: UInt64) -> Bool { awaited.contains(generation) }

    func capture(_ event: NSEvent) { events.append(event) }

    func prepend(_ earlier: ArraySlice<NSEvent>) { events.insert(contentsOf: earlier, at: 0) }

    func take() -> [NSEvent] {
        defer { events.removeAll() }
        return events
    }
}
