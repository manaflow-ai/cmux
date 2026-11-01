import AppKit
import CmuxNextActions
import CmuxNextTerminal
import os

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
///
/// The person's new workspace with a terminal (`newTab` shown in this window, ``beginWorkspace(in:)``) holds the keys
/// until the window shows that workspace and its terminal has the keyboard; keys typed for it never go anywhere else (a
/// failed or never shown workspace drops them). It also claims the window's keyboard (`KeyboardClaims`) until the
/// person's next intent there; after the hold, every key that runs no binding is still kept from the window, and no
/// primary input takes the window's keyboard by itself (``claimsKeyboard(in:generation:)``).
@MainActor
final class CreationInputCoordinator {
    weak var router: KeyRouter?
    private var buffers: [Int: CreationInputBuffer] = [:]
    /// The person's new terminal's claim on each window's keyboard (``beginWorkspace(in:)``).
    let claims = KeyboardClaims()
    /// Set while a captured key runs again, so it is not captured a second time.
    private var replaying = false
    /// The longest a key waits for a selected terminal's surface (the slowest takes about 350 ms).
    var holdLimit: Duration = .seconds(2)

    /// Why a window's creation hold ended (R-L5: its end is a signal). `focusLanded`: every creation of the hold replied
    /// and the focus it asked for holds, with a responder that takes the keys. `limitReached`: the hold's 2 s bound ended
    /// it first, so the keys typed for the new terminal went on up to that late; logged, as a person feels it.
    /// `focusLeft`: a key went to a field outside the content (a sidebar or bar field), which ends any hold. `windowClosed`.
    /// `creationFailed`: a creation of the hold failed (the daemon refused it, or the connection ended); no focus landed.
    enum HoldEnd: Equatable, Sendable {
        case focusLanded, limitReached, focusLeft, windowClosed, creationFailed
    }

    /// Windows whose current hold had a creation that failed: its unforced end is ``HoldEnd/creationFailed``.
    private var failedCreation: Set<Int> = []

    /// How the last creation hold of each window ended, by window number (tests, `debug.focus`).
    private(set) var lastHoldEnd: [Int: HoldEnd] = [:]

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "focus.creation-hold")

    /// How `window`'s last creation hold ended; nil when it never held.
    func lastHoldEnd(in window: NSWindow?) -> HoldEnd? { window.flatMap { lastHoldEnd[$0.windowNumber] } }

    /// Whether `window`'s keys wait in a creation hold now (tests: a key typed meanwhile is replayed later).
    func isHolding(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return buffers[window.windowNumber] != nil
    }

    init(router: KeyRouter) { self.router = router }

    /// The person acted in `window` (a click, a focus move of theirs, one of their actions), answering input `event`:
    /// a claim there ends, and the keys go where they put them. The input that asked for the claim does not end it.
    func personActed(in window: NSWindow?, event: NSEvent?) {
        guard let window, !claims.isEmpty else { return }
        claims.personActed(in: router?.focus(for: window).0?.window ?? window, inputTimestamp: event?.timestamp)
    }

    /// Whether `window`'s claim holds: the window does not show the claimed workspace yet. A claim that ended goes.
    private func claimHolds(in window: NSWindow) -> Bool {
        let controller = router?.focus(for: window).0
        return claims.holds(in: window, isOpen: controller != nil, shown: controller?.focus.currentState().topology.workspace)
    }

    /// A key of `window` while its claim holds and no creation hold does (the terminal never showed). Escape ends the
    /// claim and goes on. A key that runs a binding (Ctrl-Tab, a leader, Cmd-T) or the next key of a pending chord goes
    /// on: the action it runs is the person's next intent. Every other key (text, Return, Cmd-V) is kept from the window:
    /// the terminal it was typed for is not there, and no other input (Home's message box) takes it.
    private func keepsFromWindow(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard !claims.isEmpty, claimHolds(in: window), let router, let controller = router.focus(for: window).0 else { return false }
        if event.keyCode == ChordTracker.escapeKeyCode {
            claims.end(in: window)
            // The window's focus applies again, now that no claim refuses its primary input.
            if let pane = controller.focus.state.pane { controller.focus.send(.contentPresented(pane: pane)) }
            return false
        }
        if router.chords.isPending { return false }
        let context = router.keyContext(for: controller.focus.currentState(), facts: router.facts(in: window, controller: controller))
        return router.resolve(event, context: context) == nil
    }

    /// Opens the window's buffer for a new workspace with a terminal that `controller`'s window will show (`newTab`
    /// with focus), under a new user intent of its focus, and claims the window's keyboard; nil when the run may not
    /// move focus. Resolve it with ``resolve(_:workspace:in:)``.
    func beginWorkspace(in controller: WindowController?) -> CreationInputBuffer.Ticket? {
        guard let controller, let window = controller.window, ActionRunScope.viewChangeAllowed() else { return nil }
        let ticket = buffer(in: window).open(generation: controller.focus.beginIntent(), newWorkspace: true)
        claims.begin(in: window, inputTimestamp: router?.registry.dispatchingInputEvent()?.timestamp, ticket: ticket)
        return ticket
    }

    /// Whether a creation in `window` that the person has not moved on from (no user intent since it was asked for)
    /// holds its keys: the keyboard is that creation's, so a primary input (Home's message box) does not take it by
    /// itself (`NSWindow.pendingCreationOwnsKeyboard`).
    func claimsKeyboard(in window: NSWindow, generation: UInt64) -> Bool {
        if !claims.isEmpty, claimHolds(in: window) { return true }
        guard let buffer = buffers[window.windowNumber], buffer.holdsCreation else { return false }
        return buffer.newestGeneration == generation
    }

    /// Opens the window's buffer for one creation that moves focus under the user intent
    /// `generation`; nil without a window, or when the creation may not move focus (a CLI,
    /// script or agent run without `focus`), which leaves the keys where they are.
    func begin(in window: NSWindow?, generation: UInt64?, earlyTab: String? = nil, tab: String? = nil) -> CreationInputBuffer.Ticket? {
        guard let window, let generation, ActionRunScope.viewChangeAllowed() else { return nil }
        return buffer(in: window).open(generation: generation, earlyTab: earlyTab, tab: tab)
    }

    /// A creation's placement continues after its create reply (Home moves the new terminal beside
    /// its dock). Open the placement's ticket before the creator resolves its own, so held keys
    /// cannot run into the old terminal during the move. A move without a creation adds no hold.
    func continueCreation(in window: NSWindow?, generation: UInt64?) -> CreationInputBuffer.Ticket? {
        guard hasPendingCreation(in: window) else { return nil }
        return begin(in: window, generation: generation)
    }

    /// Whether a creation or its asynchronous placement is still outstanding in this window.
    func hasPendingCreation(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return buffers[window.windowNumber]?.hasPendingCreation == true
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
            if let window { flush(in: window, force: true, end: .limitReached) } else { buffers[number] = nil }
        }
        return buffer
    }

    /// The creation behind `ticket` got its reply (`landed`: its focus was asked for) or failed.
    /// The keys go on in a new main-actor turn: outside the creation's task (its action scope)
    /// and after the focus events the reply queued.
    func resolve(_ ticket: CreationInputBuffer.Ticket?, landed: Bool, in window: NSWindow?) {
        resolve(ticket, landed: landed, workspace: nil, in: window)
    }

    /// The new workspace behind `ticket` (``beginWorkspace(in:)``) was made (`workspace`, its id) or not (nil: it
    /// failed or a close took it, and the keys typed for it go with it).
    func resolve(_ ticket: CreationInputBuffer.Ticket?, workspace: String?, in window: NSWindow?) {
        resolve(ticket, landed: workspace != nil, workspace: workspace, in: window)
    }

    private func resolve(_ ticket: CreationInputBuffer.Ticket?, landed: Bool, workspace: String?, in window: NSWindow?) {
        // The window may show the claimed workspace already (its delta came before the reply): the claim ends here.
        if let ticket, let window, let workspace, claims.noteMade(workspace, by: ticket, in: window) { _ = claimHolds(in: window) }
        guard let ticket, let window, let buffer = buffers[window.windowNumber] else { return }
        if !landed { failedCreation.insert(window.windowNumber) }
        buffer.resolve(ticket, awaitsFocus: landed, workspace: workspace)
        scheduleFlush(in: window)
        // The focus it asked for may never land (a split from a page tab shows a New Tab page):
        // the keys go on `holdLimit` after the reply at the latest.
        let number = window.windowNumber
        buffer.expire(after: holdLimit) { [weak self, weak window] buffer in
            guard let self, buffers[number] === buffer else { return }
            if let window { flush(in: window, force: true, end: .limitReached) } else { buffers[number] = nil }
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
        guard let buffer = buffers[shell.windowNumber] else { return kind == .content && keepsFromWindow(event, in: shell) }
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
            flush(in: shell, force: true, end: .focusLeft)
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
        // A claim whose workspace the window shows now ends here, not at a later key (it must not hold again if the
        // window goes back to Home without the person).
        if let window, !claims.isEmpty { _ = claimHolds(in: window) }
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
    /// `end`: why a forced end happened; an unforced one is ``HoldEnd/focusLanded``.
    private func flush(in window: NSWindow, force: Bool = false, end forcedEnd: HoldEnd = .limitReached) {
        guard let buffer = buffers[window.windowNumber], force || buffer.isResolved else { return }
        guard let router, let controller = router.focus(for: window).0 else {
            // The window is gone: its keys go with it.
            buffers[window.windowNumber] = nil
            failedCreation.remove(window.windowNumber)
            lastHoldEnd[window.windowNumber] = .windowClosed
            return
        }
        // Reduced: a topology the window marked changed counts (the new workspace may show in this turn).
        let shown = controller.focus.currentState().topology.workspace
        if !force {
            let focus = controller.focus.state
            if let expectation = focus.expectation, buffer.awaits(expectation.generation) { return }
            // A new workspace's keys wait for the window to show it (its terminal then has the keyboard, below).
            if let workspace = buffer.awaitedWorkspace, workspace != shown { return }
            guard Self.responderTakesKeys(controller, window: window) else { return }
        }
        buffers[window.windowNumber] = nil
        let failed = failedCreation.remove(window.windowNumber) != nil
        let end = force ? forcedEnd : failed ? .creationFailed : .focusLanded
        lastHoldEnd[window.windowNumber] = end
        // A forced end (its limit, focus left the content) drops the keys of a new workspace the window does not show,
        // and the window's focus applies again so the responder matches the focus model; the claim stays until the
        // person's next intent, so a primary input (Home's message box) still does not take the keyboard.
        let unshown = buffer.waitsForWorkspace(other: shown)
        let pending = buffer.take(shown: shown)
        if unshown, let pane = controller.focus.state.pane { controller.focus.send(.contentPresented(pane: pane)) }
        if end == .limitReached {
            // The person's keys for a new terminal waited the whole bound and go on now, into whatever has the focus.
            Self.logger.notice("creation hold of window \(window.windowNumber, privacy: .public) ended at its limit, not on focus: \(pending.count, privacy: .public) held key(s) go on now; last action \(router.lastInterception?.action.rawValue ?? "-", privacy: .public)")
        }
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

extension CreationInputCoordinator {
    /// Each of the person's actions (a key binding, the menu, the palette, a click's action) is their next intent in the
    /// active window: a claim there ends (``personActed(in:event:)``). Runs before the action's handler, so a new
    /// terminal the action asks for claims the keyboard again.
    static func installPersonIntent(_ services: AppServices) {
        services.registry.willRunObservers.append { [weak services] _, origin in
            // Only a top-level run is a new intent: a run inside another (its handler's, or a later turn of an earlier
            // run, whose task keeps that run's scope) answers no new press.
            guard origin == .user, ActionRunScope.current == nil, let services else { return }
            services.keyRouter.creationInputCoordinator.personActed(in: services.windows.active?.window,
                                                                    event: services.registry.dispatchingInputEvent())
        }
    }
}

extension WindowController {
    /// A text input has this window's keyboard: an editable text view or field (empty or not), text an input method
    /// composes, or an editable element of the focused page (a web form field, an editor). Only while the app is active
    /// and the key window is this window or one it owns (a Chromium page window, a sheet: the shell resigns key then);
    /// a CLI run from another app finds the keyboard elsewhere. A terminal is not a text input here. A script's new
    /// workspace does not take the window from such an input (CLAUDE.md, "Go past Chrome where cmux is scripted").
    var hasTextInputKeyboard: Bool {
        let facts = focus.currentState()
        guard let window, facts.appActive,
              facts.windowKey || NSApp.keyWindow.flatMap(services.windows.owner(of:)) === self else { return false }
        return window.firstResponderTypesText(excluding: { $0 is TerminalSurfaceView })
            || services.keyRouter.facts(in: window, controller: self).pageEditableFocused
    }
}
