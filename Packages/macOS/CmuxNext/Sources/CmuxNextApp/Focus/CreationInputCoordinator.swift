import AppKit
import CmuxNextActions
import CmuxNextFocus
import CmuxNextFocusUI
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
/// The person's new workspace with a terminal (`newTab` shown in this window, `beginWorkspace`) holds the keys the same
/// way until the window shows that workspace and its terminal has the keyboard; keys typed for it never go anywhere else
/// (a failed or never shown workspace drops them). It also claims the window's keyboard (`KeyboardClaim`) until the
/// person's next intent there: a click, Escape, a focus move of theirs (mouse, keyboard, palette), another of their
/// actions; or until the window shows it. Never by a timeout, and never by automation (a script's focus move or intent).
/// After the hold, every key that runs no binding is still kept from the window. While a claim or a
/// creation the person has not moved on from holds a window's keys, no primary input takes that window's keyboard by
/// itself (``claimsKeyboard(in:generation:)``). Dogfood v2.2.3: Home's Chief message box took the keys typed for a new
/// terminal and sent a shell command to the Chief as a message; terminal input must never reach an agent.
@MainActor
final class CreationInputCoordinator {
    weak var router: KeyRouter?
    /// The router's typing keys come here only while some window holds keys (``KeyRouterMode/creationCapture``).
    private var buffers: [Int: CreationInputBuffer] = [:] { didSet { syncMode() } }
    /// The person's new terminal's claim on a window's keyboard, by window number (``beginWorkspace(in:)``).
    private var claims: [Int: KeyboardClaim] = [:] { didSet { syncMode() } }
    /// Set while a captured key runs again, so it is not captured a second time.
    private var replaying = false
    /// Held keys run again since launch (tests: a key must never be run into a view it was not typed for).
    private(set) var replayedCount = 0
    /// The longest a key waits for a selected terminal's surface (the slowest takes about 350 ms).
    var holdLimit: Duration = .seconds(2)

    /// How each window's creation holds ended (``CreationHoldEnd``, R-L5: its end is a signal).
    private(set) var holdEnds = CreationHoldLog()

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "focus.creation-hold")

    /// How `window`'s last creation hold ended; nil when it never held.
    func lastHoldEnd(in window: NSWindow?) -> CreationHoldEnd? { window.flatMap { holdEnds.last[$0.windowNumber] } }

    init(router: KeyRouter) { self.router = router }

    /// A window's keyboard belongs to the person's new terminal, asked for under focus generation `generation`.
    private final class KeyboardClaim {
        let generation: UInt64
        weak var window: NSWindow?
        /// The workspace the create made (nil until its reply, or when it failed).
        var workspace: String?
        /// The timestamp of the person's input that asked for it (a click on a New Workspace button): that input's own
        /// end does not end the claim it made.
        let inputTimestamp: TimeInterval?
        /// The hold of the create that made it: only that create's reply names its workspace.
        var ticket: CreationInputBuffer.Ticket?

        init(generation: UInt64, window: NSWindow, inputTimestamp: TimeInterval?) {
            self.generation = generation
            self.window = window
            self.inputTimestamp = inputTimestamp
        }
    }

    /// A claim whose window is gone holds nothing: it neither keeps the mode on nor slows keys.
    private func syncMode() { router?.modes.set(.creationCapture, !buffers.isEmpty || claims.values.contains { $0.window != nil }) }

    /// `window` closed: its claim goes with it.
    func windowClosed(_ window: NSWindow?) {
        guard let window else { return }
        claims[window.windowNumber] = nil
    }

    /// The person acted in `window` (a click after its dispatch, a focus move of theirs, one of their actions), answering
    /// input `event`: a claim there ends, and the keys go where they put them. The input that asked for the claim (the
    /// click or key of New Workspace) does not end it.
    func personActed(in window: NSWindow?, event: NSEvent?) {
        guard let window, !claims.isEmpty else { return }
        let shell = router?.focus(for: window).0?.window ?? window
        if let event, let made = claims[shell.windowNumber]?.inputTimestamp, made == event.timestamp { return }
        claims[shell.windowNumber] = nil
    }

    /// `window`'s claim while it holds: the window does not show the claimed workspace yet (the person's own intents end it
    /// through ``personActed(in:event:)``). A claim that ended is removed here.
    private func activeClaim(in window: NSWindow) -> KeyboardClaim? {
        let number = window.windowNumber
        guard let claim = claims[number] else { return nil }
        guard claim.window === window, let controller = router?.focus(for: window).0 else {
            claims[number] = nil
            return nil
        }
        if let workspace = claim.workspace, workspace == controller.focus.currentState().topology.workspace {
            claims[number] = nil
            return nil
        }
        return claim
    }

    /// A key of `window` while its claim holds and no creation hold does (the terminal never showed). Escape ends the
    /// claim and goes on. A key that runs a binding (Ctrl-Tab, a leader, Cmd-T) or the next key of a pending chord goes
    /// on: the action it runs is the person's next intent. Every other key (text, Return, Cmd-V) is kept from the window:
    /// the terminal it was typed for is not there, and no other input (Home's message box) takes it.
    private func keepsFromWindow(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard activeClaim(in: window) != nil, let router else { return false }
        if event.keyCode == ChordTracker.escapeKeyCode {
            claims[window.windowNumber] = nil
            // The window's focus applies again, now that no claim refuses its primary input.
            if let controller = router.focus(for: window).0, let pane = controller.focus.state.pane {
                controller.focus.send(.contentPresented(pane: pane))
            }
            return false
        }
        if router.chords.isPending { return false }
        if let controller = router.focus(for: window).0 {
            let context = router.keyContext(for: controller.focus.currentState(), facts: router.facts(in: window, controller: controller))
            if router.resolve(event, context: context) != nil { return false }
        }
        return true
    }

    /// Opens the window's buffer for one creation that moves focus under the user intent
    /// `generation`; nil without a window, or when the creation may not move focus (a CLI,
    /// script or agent run without `focus`), which leaves the keys where they are.
    func begin(in window: NSWindow?, generation: UInt64?, earlyTab: String? = nil, tab: String? = nil) -> CreationInputBuffer.Ticket? {
        guard let window, let generation, ActionRunScope.viewChangeAllowed() else { return nil }
        defer { router?.newTabInputCoordinator.creationTookKeys(in: window) } // the newer intent: a New Tab hold's keys come here, in order
        return buffer(in: window).open(generation: generation, earlyTab: earlyTab, tab: tab)
    }

    /// Opens the window's buffer for a new workspace with a terminal that `window` will show (`newTab` with focus),
    /// under a new user intent of that window's focus; nil when the run may not move focus. Resolve it with
    /// ``resolve(_:workspace:in:)``.
    func beginWorkspace(in controller: WindowController?) -> CreationInputBuffer.Ticket? {
        guard let controller, let window = controller.window, ActionRunScope.viewChangeAllowed() else { return nil }
        let generation = controller.focus.beginIntent()
        let input = router?.registry.dispatchingInputEvent()
        let claim = KeyboardClaim(generation: generation, window: window, inputTimestamp: input?.timestamp)
        claims[window.windowNumber] = claim
        let ticket = buffer(in: window).open(generation: generation, newWorkspace: true)
        claim.ticket = ticket
        return ticket
    }

    /// Whether a creation in `window` that the person has not moved on from (no user intent since it was asked for)
    /// holds its keys: the keyboard is that creation's, so a primary input (Home's message box) does not take it by
    /// itself (`NSWindow.pendingCreationOwnsKeyboard`).
    func claimsKeyboard(in window: NSWindow, generation: UInt64) -> Bool {
        if activeClaim(in: window) != nil { return true }
        guard let buffer = buffers[window.windowNumber], buffer.holdsCreation else { return false }
        return buffer.newestGeneration == generation
    }

    /// Whether `window` has a claim recorded now, ended or not (tests, `debug.focus`).
    func hasClaim(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return claims[window.windowNumber] != nil
    }

    /// Why `window`'s held keys would or would not go to a pending creation's early view now (tests' failure reports).
    func earlyDeliveryState(in window: NSWindow) -> String {
        guard let buffer = buffers[window.windowNumber] else { return "no hold" }
        guard let controller = router?.focus(for: window).0 else { return "no controller" }
        let early = takesKeysEarly(buffer, controller: controller, window: window)
        let pane: String? = if case .terminal(let pane, _) = controller.focus.state.resolved { pane } else { nil }
        let shows = pane.flatMap { controller.content?.paneController(key: $0)?.currentTabKey } ?? "-"
        return "resolved \(buffer.isResolved), held \(buffer.count), newestEarlyTab \(buffer.newestEarlyTab ?? "-"), "
            + "focus \(controller.focus.state.resolved), pane shows \(shows), takesKeysEarly \(early)"
    }

    /// How many keys `window`'s hold keeps now (tests).
    func heldCount(in window: NSWindow?) -> Int {
        guard let window else { return 0 }
        return buffers[window.windowNumber]?.count ?? 0
    }

    /// Whether `window`'s keys wait in a creation hold now (tests, `debug.focus`).
    func isHolding(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return buffers[window.windowNumber] != nil
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
        if let window, let workspace, let ticket, let claim = claims[window.windowNumber], claim.ticket == ticket {
            claim.workspace = workspace
            _ = activeClaim(in: window) // the window may show it already (its delta came before the reply)
        }
        guard let ticket, let window, let buffer = buffers[window.windowNumber] else { return }
        if !landed { holdEnds.creationFailed(in: window.windowNumber) }
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
        guard let buffer = buffers[shell.windowNumber] else {
            droppedLastKey = kind == .content && keepsFromWindow(event, in: shell)
            return droppedLastKey
        }
        droppedLastKey = false
        // A close key (Cmd-W) acts now on what it closes; held, it ran later with the other keys.
        let closes = controller.map { Self.closes(event, in: shell, controller: $0, router: router) } ?? false
        // A close of a pending creation of this hold (the focus it asked for is still on its way):
        // the keys typed for it go with it, the others keep waiting in order, and the close runs now
        // (TabLifecycle cancels the creation). Nothing is run into whatever has the focus first.
        if closes, let controller, let tab = Self.creatingTab(of: controller, in: buffer) {
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
        // Every creation replied and what they asked for holds now (focus landed, the new terminal has the keyboard):
        // the hold ends at this key, its held keys first, then this one goes on. A settle is not waited for: none may
        // come after the terminal took the keyboard, and the keys then waited for the hold's bound
        // (first-keys-proof item 2).
        if buffer.isResolved {
            flush(in: shell)
            guard let next = buffers[shell.windowNumber] else {
                // As any key after a hold: a person's keyboard claim still keeps it from the window (the Chief's box).
                // A replayed key may have moved focus out of the content (the address bar): read it again.
                droppedLastKey = router.focus(for: window).1 == .content && keepsFromWindow(event, in: shell)
                return droppedLastKey
            }
            guard next === buffer else {
                // A held key run again started another hold: this one waits in it, in order, if that hold keeps it (a
                // chord passes an empty surface hold, as on the forced path above).
                guard next.holds(event, limit: holdLimit, expiring: false, closes: closes) else { return false }
                next.capture(event)
                return true
            }
        }
        // A pending creation's early view has the keyboard: held keys first, then this one.
        if let controller, takesKeysEarly(buffer, controller: controller, window: shell) {
            guard deliverEarly(buffer, in: shell, router: router) else {
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

    /// The pending creation of `buffer` that `controller`'s focus asks for (its expectation) or already names (focus
    /// landed on it before the reply): a close key then closes it, and the keys typed for it go with it.
    private static func creatingTab(of controller: WindowController, in buffer: CreationInputBuffer) -> String? {
        let focus = controller.focus.state
        if case .tab(let tab)? = focus.expectation?.key, buffer.isCreating(tab: tab) { return tab }
        if case .terminal(_, let tab) = focus.resolved, buffer.isCreating(tab: tab) { return tab }
        return nil
    }

    /// Ctrl-` stand-in tab `key` became the daemon's tab `real` (`TabContentCache.adoptStandIn`): the holds that wait
    /// for it follow it, so its view still takes the keys early and a close of it still drops them.
    func standInAdopted(_ key: String, as real: String) {
        for buffer in buffers.values { buffer.rekey(tab: key, to: real) }
    }

    /// The last key ``capture(_:in:)`` took was dropped (a keyboard claim kept it from the window), not held.
    private(set) var droppedLastKey = false

    /// Whether a pending creation's early view (its terminal, which sends keys to the daemon by the terminal id the
    /// create chose, cx-wb5.78) is the focused terminal and has the keyboard: keys go to it now, not after the reply.
    /// Only that view: focus names the newest pending creation's early tab, its pane shows it, and the window's first
    /// responder is its terminal (never another terminal, an agent's composer or Home's message box).
    private func takesKeysEarly(_ buffer: CreationInputBuffer, controller: WindowController, window: NSWindow) -> Bool {
        guard case .terminal(let pane, let tab) = controller.focus.state.resolved, buffer.newestEarlyTab == tab,
              let paneController = controller.content?.paneController(key: pane), paneController.currentTabKey == tab,
              case .terminal(let entry)? = paneController.currentContent,
              let responder = window.firstResponder as? NSView else { return false }
        return responder === entry.session.surfaceView || responder.isDescendant(of: entry.session.view)
    }

    /// Runs the held keys into the early view that has the keyboard, in order, at once. False when a key run again
    /// started another creation: the rest wait for it, in order.
    private func deliverEarly(_ buffer: CreationInputBuffer, in window: NSWindow, router: KeyRouter) -> Bool {
        let held = buffer.take(), opened = buffer.openedCount
        for (index, key) in held.enumerated() {
            runAgain(key, in: window, router: router)
            if buffer.openedCount != opened {
                buffer.prepend(held.dropFirst(index + 1))
                return false
            }
        }
        return true
    }

    /// Runs held key `event` of `window` again through the seam (``HeldKeyReplay``, held_by `creation`), so the hold is
    /// a measured stage in `debug.input late_keys`. It goes through `NSApplication.sendEvent`, as typed (the key router,
    /// key equivalents and the menu included), which opens its one latency slot. `replaying` keeps it from being captured
    /// again by this hold.
    private func runAgain(_ event: NSEvent, in window: NSWindow, router: KeyRouter) {
        replaying = true
        replayedCount += 1
        router.heldKeys.replay(event, heldBy: .creation, keyWindow: window, throughApplication: true) { $0.application(event) }
        replaying = false
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
        if let window, !claims.isEmpty { _ = activeClaim(in: window) }
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
    /// A pending creation whose early view got the keyboard takes the held keys now: the hold stays (later keys go
    /// straight to that view through ``capture(_:in:)``) until the creation resolves.
    /// `end`: why a forced end happened (``CreationHoldLog/end(in:forced:)``).
    private func flush(in window: NSWindow, force: Bool = false, end forcedEnd: CreationHoldEnd = .limitReached) {
        guard let buffer = buffers[window.windowNumber] else { return }
        if !force, !buffer.isResolved {
            if !buffer.isEmpty, let router, let controller = router.focus(for: window).0,
               takesKeysEarly(buffer, controller: controller, window: window) {
                _ = deliverEarly(buffer, in: window, router: router)
            }
            return
        }
        guard let router, let controller = router.focus(for: window).0 else {
            // The window is gone: its keys go with it.
            buffers[window.windowNumber] = nil
            holdEnds.windowClosed(window.windowNumber)
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
        // A forced end (its limit, focus left the content) drops the keys of a new workspace the window does not show.
        let unshown = buffer.waitsForWorkspace(other: shown)
        let pending = buffer.take(shown: shown)
        let end = holdEnds.end(in: window.windowNumber, forced: force ? forcedEnd : nil)
        if end == .limitReached {
            // The person's keys for a new terminal waited the whole bound and go on now, into whatever has the focus.
            Self.logger.notice("creation hold of window \(window.windowNumber, privacy: .public) ended at its limit, not on focus: \(pending.count, privacy: .public) held key(s) go on now; last action \(router.lastInterception?.action.rawValue ?? "-", privacy: .public)")
        }
        // The window's focus applies again, so the responder matches the focus model. The person's claim on the keyboard
        // stays until their next intent, so a primary input (Home's message box) still does not take it.
        if unshown, let pane = controller.focus.state.pane { controller.focus.send(.contentPresented(pane: pane)) }
        for (index, event) in pending.enumerated() {
            runAgain(event, in: window, router: router)
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
    /// active window: a claim there ends (``personActed(in:)``). Runs before the action's handler, so a new terminal the
    /// action asks for claims the keyboard again.
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
