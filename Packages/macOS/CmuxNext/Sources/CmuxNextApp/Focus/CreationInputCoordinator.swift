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
///
/// The same hold covers Ctrl-1…9 onto a terminal tab with no surface yet (hq#1925 item 3; bound
/// in `CreationInputBuffer.holds`). Any hold ends as soon as focus leaves the content (cx-wb5.78: `earlyTab`).
@MainActor
final class CreationInputCoordinator {
    weak var router: KeyRouter?
    private var buffers: [Int: CreationInputBuffer] = [:]
    /// Set while a captured key runs again, so it is not captured a second time.
    private var replaying = false
    /// The longest a key waits for a selected terminal's surface (the slowest takes about 350 ms).
    var holdLimit: Duration = .seconds(2)

    init(router: KeyRouter) { self.router = router }

    /// Opens the window's buffer for one creation that moves focus under the user intent
    /// `generation`; nil without a window, or when the creation may not move focus (a CLI,
    /// script or agent run without `focus`), which leaves the keys where they are.
    func begin(in window: NSWindow?, generation: UInt64?, earlyTab: String? = nil, tab: String? = nil) -> CreationInputBuffer.Ticket? {
        guard let window, let generation, ActionRunScope.viewChangeAllowed() else { return nil }
        return buffer(in: window).open(generation: generation, earlyTab: earlyTab, tab: tab)
    }

    /// The person closed provisional tab `tab` in `window` before the daemon made it: the keys held
    /// for it are dropped and the rest go on (``CreationInputBuffer/cancel(tab:)``).
    func drop(tab: String, in window: NSWindow?) {
        if let window, buffers[window.windowNumber]?.cancel(tab: tab) == true { scheduleFlush(in: window) }
    }

    /// A selection shows a terminal whose surface comes later: keys wait for it, at most `holdLimit`.
    func holdUntilShown(in window: NSWindow?) {
        guard let window, ActionRunScope.viewChangeAllowed() else { return }
        _ = buffer(in: window)
    }

    private func buffer(in window: NSWindow) -> CreationInputBuffer {
        let number = window.windowNumber
        if let buffer = buffers[number] { return buffer }
        let buffer = CreationInputBuffer(began: ContinuousClock.now)
        buffers[number] = buffer
        buffer.expire(after: holdLimit) { [weak self, weak window] buffer in
            guard let self, buffers[number] === buffer else { return }
            if let window { flush(in: window, force: true) } else { buffers[number] = nil }
        }
        return buffer
    }

    /// The creation behind `ticket` got its reply (`landed`: its focus was asked for) or failed.
    /// The keys go on in a new main-actor turn: outside the creation's task (its action scope)
    /// and after the focus events the reply queued.
    func resolve(_ ticket: CreationInputBuffer.Ticket?, landed: Bool, in window: NSWindow?) {
        guard let ticket, let window, let buffer = buffers[window.windowNumber] else { return }
        buffer.resolve(ticket, awaitsFocus: landed)
        scheduleFlush(in: window)
        // The focus it asked for may never land (a split from a page tab shows a New Tab page):
        // the keys go on `holdLimit` after the reply at the latest.
        let number = window.windowNumber
        buffer.expire(after: holdLimit) { [weak self, weak window] buffer in
            guard let self, buffers[number] === buffer else { return }
            if let window { flush(in: window, force: true) } else { buffers[number] = nil }
        }
    }

    /// Whether `event`'s binding in `controller`'s focus is a close action (Close Tab, Cmd-W).
    private static func closes(_ event: NSEvent, in window: NSWindow, controller: WindowController, router: KeyRouter) -> Bool {
        guard KeyRouter.isChord(event.modifierFlags) else { return false }
        let context = router.keyContext(for: controller.focus.currentState(), facts: router.facts(in: window, controller: controller))
        guard let binding = router.resolve(event, context: context) else { return false }
        return WindowKeyTable.isClose(binding.command)
    }

    /// Takes `event` while a creation in its window is pending.
    func capture(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard !replaying, let router, let window else { return false }
        let (controller, kind) = router.focus(for: window)
        // A Chromium page window is a child of the shell, whose number keys the buffer.
        let shell = controller?.window ?? window
        guard let buffer = buffers[shell.windowNumber] else { return false }
        // A close key (Cmd-W) acts now on what it closes; held, it ran later with the other keys.
        let closes = controller.map { Self.closes(event, in: shell, controller: $0, router: router) } ?? false
        // A close of a pending creation of this hold (the focus it asked for is still on its way):
        // the keys typed for it go with it, the others keep waiting in order, and the close runs now
        // (TabLifecycle cancels the creation). Nothing is run into whatever has the focus first.
        if closes, let controller, case .tab(let tab)? = controller.focus.state.expectation?.key, buffer.isCreating(tab: tab) {
            _ = buffer.cancel(tab: tab)
            scheduleFlush(in: shell)
            return false
        }
        // Focus left the content (a sidebar or bar field) or the hold lets this key go: the held
        // keys go on first, then this one (into a hold a replayed key opened, if it keeps it).
        guard kind == .content, controller != nil, buffer.holds(event, limit: holdLimit, expiring: true, closes: closes) else {
            flush(in: shell, force: true)
            guard let next = buffers[shell.windowNumber], next.holds(event, limit: holdLimit, expiring: false, closes: closes) else { return false }
            next.capture(event)
            return true
        }
        // A pending creation's early view has the keyboard: held keys first, then this one.
        if let controller, case .terminal(_, let tab) = controller.focus.state.resolved, buffer.takesKeysEarly(tab: tab), Self.responderTakesKeys(controller, window: shell) {
            let held = buffer.take(), opened = buffer.openedCount
            for (index, key) in held.enumerated() {
                replaying = true
                NSApp.sendEvent(key)
                replaying = false
                // A key run again started another creation: the rest, and this key, wait for it, in order.
                if buffer.openedCount != opened {
                    buffer.prepend(held.dropFirst(index + 1))
                    buffer.capture(event)
                    return true
                }
            }
            return false
        }
        buffer.capture(event)
        return true
    }

    /// Keys the daemon gave back from terminal `terminalID`, a creation that did not take them: they
    /// wait for a focused terminal of the window that showed that terminal, never another window's.
    /// Keys from a terminal no window shows any more are dropped (never typed into a guess).
    func giveBack(_ bytes: Data, terminal terminalID: String) {
        GivenBackInput.shared.deliver(adding: bytes, window: window(ofCreatingTerminal: terminalID), to: nil)
        giveBack()
    }

    /// Hands held give-back keys to the focused terminal (the key window's), when it is in their window.
    func giveBack() {
        guard let services = router?.services else { return }
        let focused = services.cache.terminals.values.first { $0.session.model.isFocused && $0.gate == nil }
        let window = focused?.session.view.window.flatMap { services.windows.owner(of: $0)?.state.id }
        GivenBackInput.shared.deliver(window: window, to: focused.map { $0.session.sendBytes })
    }

    /// The cmux window showing the view of terminal `terminalID`, still being created.
    private func window(ofCreatingTerminal terminalID: String) -> String? {
        guard let services = router?.services,
              let entry = services.cache.terminals.values.first(where: { $0.io.creatingTerminalID == terminalID }),
              let window = entry.session.view.window else { return nil }
        return services.windows.owner(of: window)?.state.id
    }

    /// A focus settle in `window`: the keys may go on (in a new turn, after the focus queue).
    func focusDidSettle(in window: NSWindow?) {
        giveBack()
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
    private func flush(in window: NSWindow, force: Bool = false) {
        guard let buffer = buffers[window.windowNumber], force || buffer.isResolved else { return }
        guard let router, let controller = router.focus(for: window).0 else {
            // The window is gone: its keys go with it.
            buffers[window.windowNumber] = nil
            return
        }
        if !force {
            let focus = controller.focus.state
            if let expectation = focus.expectation, buffer.awaits(expectation.generation) { return }
            guard Self.responderTakesKeys(controller, window: window) else { return }
        }
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
    /// False while focus names a terminal whose view does not have the keyboard and the window's
    /// first responder is another terminal or the window itself (a remounted view), or names the
    /// pane's selected terminal before its surface is shown: a key now would land in the wrong
    /// terminal or nowhere. Anything else takes the keys.
    static func responderTakesKeys(_ controller: WindowController, window: NSWindow) -> Bool {
        guard case .terminal(let pane, let tab) = controller.focus.state.resolved,
              let paneController = controller.content?.paneController(key: pane) else { return true }
        // Selected, its surface still to come (the pane is empty meanwhile).
        if paneController.currentTabKey != tab { return paneController.stripModel.selectedID?.rawValue != tab }
        guard case .terminal(let entry)? = paneController.currentContent else { return true }
        guard let responder = window.firstResponder as? NSView else { return false }
        if responder === entry.session.surfaceView || responder.isDescendant(of: entry.session.view) { return true }
        return !(responder is TerminalSurfaceView)
    }
}
