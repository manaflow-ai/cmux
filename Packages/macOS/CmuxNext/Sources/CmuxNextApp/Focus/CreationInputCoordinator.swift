import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextFocus
import CmuxNextFocusUI
import CmuxNextTerminal
import os

/// Where a creation hold's keys run again (#28436): `AppDelegate` passes `NSApp.sendEvent`, to the key window a person types
/// in; a test, whose window is never key, passes its window. Arguments: the key, the window that held it, the key router.
typealias HeldKeyReplay = @MainActor (NSEvent, NSWindow, KeyRouter) -> Void

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
/// The person's new workspace with a terminal (``beginWorkspace(in:)``) holds its keys until the window shows it, and claims
/// the window's keyboard until their next intent there (`CreationKeyboardClaims`): terminal input never reaches an agent.
@MainActor
final class CreationInputCoordinator {
    weak var router: KeyRouter?
    private var buffers: [Int: CreationInputBuffer] = [:]
    /// The person's new terminals' claims on their windows' keyboards (``beginWorkspace(in:)``).
    private let claims = CreationKeyboardClaims()
    /// Set while a captured key runs again (`lane`: it was held for a terminal), so it is not captured a second time.
    private var replaying: (on: Bool, lane: Bool) = (false, false)
    /// The longest a key waits for a selected terminal's surface (the slowest takes about 350 ms).
    var holdLimit: Duration = .seconds(2)
    var replyWaitLimit: Duration = CreationInputBuffer.replyWaitBound // a creation's reply keeps the keys at most this (tests: short)
    private let replay: HeldKeyReplay // a held key runs again (``HeldKeyReplay``)

    /// How each window's creation holds ended (``CreationHoldEnd``, R-L5: its end is a signal).
    var holdEnds = CreationHoldLog() // a page's arrival writes it (``CreationHoldLog/pageArrived(_:)``)

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "focus.creation-hold")

    /// How `window`'s last creation hold ended; nil when it never held.
    func lastHoldEnd(in window: NSWindow?) -> CreationHoldEnd? { window.flatMap { holdEnds.last[$0.windowNumber] } }

    /// Whether `window`'s keys wait in a creation hold now (tests: a key typed meanwhile is replayed later).
    func isHolding(in window: NSWindow?) -> Bool { window.map { buffers[$0.windowNumber] != nil } ?? false }
    init(router: KeyRouter, replay: @escaping HeldKeyReplay) { (self.router, self.replay) = (router, replay) }

    /// Holds `controller`'s keys for the person's new workspace's terminal under a new intent, and claims its keyboard;
    /// nil when the run may not move focus. Resolve it with ``resolve(_:landed:workspace:in:)``.
    func beginWorkspace(in controller: WindowController?) -> CreationInputBuffer.Ticket? {
        guard let controller, let window = controller.window, ActionRunScope.viewChangeAllowed() else { return nil }
        defer { router?.newTabInputCoordinator.creationTookKeys(in: window) } // the newer intent: a New Tab hold's keys come here, in order
        let generation = controller.focus.beginIntent()
        let ticket = buffer(in: window).open(generation: generation, newWorkspace: true, pressTerminal: Self.keyboardTerminal(controller, window).map { .init(tab: $0, machine: controller.content?.daemon.machineID) }, personMoves: controller.focus.state.personMoveSeq)
        claims.claim(window, ticket: ticket, input: router?.registry.dispatchingInputEvent()?.timestamp, intents: controller.focus.personIntents.count)
        return ticket
    }

    /// Whether a creation in `window` the person has not moved on from holds its keys, or their new terminal claims the
    /// keyboard: no primary input (Home's message box) takes it by itself (`NSWindow.pendingCreationOwnsKeyboard`).
    func claimsKeyboard(in window: NSWindow, generation: UInt64) -> Bool {
        claimHolds(in: window) || buffers[window.windowNumber]?.ownsKeyboard(generation: generation) == true
    }

    /// The person acted in `window` (a click, one of their actions), answering input `event`: their claim there ends, and the
    /// keys typed after it are no longer their new workspace's (``CreationInputBuffer/personMovedOn()``).

    func personActed(in window: NSWindow?, event: NSEvent?) {
        guard let window, !claims.isEmpty, case let number = (router?.focus(for: window).0?.window ?? window).windowNumber else { return }
        if claims.personActed(inWindow: number, input: event?.timestamp) { buffers[number]?.personMovedOn() }
    }

    /// `window` closes: its claim goes with it.
    func windowClosed(_ window: NSWindow?) { if let window { claims.end(inWindow: window.windowNumber); asking[window.windowNumber] = nil } } // its questions go with it
    /// Whether `window`'s claim holds now (``CreationKeyboardClaims/holds(in:shows:intents:lastInput:)``).
    private func claimHolds(in window: NSWindow) -> Bool {
        guard !claims.isEmpty else { return false }
        guard let focus = router?.focus(for: window).0?.focus else { claims.end(inWindow: window.windowNumber); return false }
        return claims.holds(in: window, shows: focus.currentState().topology.workspace, intents: focus.personIntents.count, lastInput: focus.personIntents.input)
    }

    /// A key of `window` while its claim holds and no hold keeps it (``CreationKeyboardClaims/keeps(_:in:chordPending:runsBinding:)``).
    private func keepsFromWindow(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard claimHolds(in: window), let router, let controller = router.focus(for: window).0 else { return false }
        let context = { router.keyContext(for: controller.focus.currentState(), facts: router.facts(in: window, controller: controller)) }
        guard let keeps = claims.keeps(event, in: window, chordPending: router.chords.isPending, runsBinding: { router.resolve(event, context: context()) != nil }) else {
            if let pane = controller.focus.state.pane { controller.focus.send(.contentPresented(pane: pane)) } // Escape: the window's focus applies again
            return false
        }
        return keeps
    }

    /// Opens the window's buffer for one creation that moves focus under the user intent
    /// `generation`; nil without a window, or when the creation may not move focus (a CLI,
    /// script or agent run without `focus`), which leaves the keys where they are.
    func begin(in window: NSWindow?, generation: UInt64?, earlyTab: String? = nil, tab: String? = nil, machine: String? = nil) -> CreationInputBuffer.Ticket? {
        guard let window, let generation, ActionRunScope.viewChangeAllowed() else { return nil }
        defer { router?.newTabInputCoordinator.creationTookKeys(in: window) } // the newer intent: a New Tab hold's keys come here, in order
        defer { if let focus = router?.focus(for: window).0?.focus, focus.state.awaitsOtherTab, let pane = focus.state.pane { focus.send(.contentPresented(pane: pane)) } } // the page the person left gives this hold the keys now (P0 INVERSE-KEY)
        return buffer(in: window).open(generation: generation, earlyTab: earlyTab, tab: tab, machine: machine ?? router?.focus(for: window).0?.content?.daemon.machineID)
    }

    /// ``CreationInputBuffer/keepsKeysFromLeftPage(awaitsOtherTab:generation:focusedTab:)`` for `window`'s hold.
    func keepsKeysFromLeftPage(_ state: FocusState, in window: NSWindow) -> Bool { buffers[window.windowNumber]?.keepsKeysFromLeftPage(awaitsOtherTab: state.awaitsOtherTab, generation: state.generation, focusedTab: state.resolved.tab) == true }

    /// A creation's placement continues after its create reply (Home moves the new terminal beside
    /// its dock). Open the placement's ticket before the creator resolves its own, so held keys
    /// cannot run into the old terminal during the move. A move without a creation adds no hold.
    func continueCreation(in window: NSWindow?, generation: UInt64?) -> CreationInputBuffer.Ticket? {
        guard hasPendingCreation(in: window) else { return nil }
        return begin(in: window, generation: generation)
    }

    /// Whether a creation or its asynchronous placement is still outstanding in this window.
    func hasPendingCreation(in window: NSWindow?) -> Bool { window.flatMap { buffers[$0.windowNumber] }?.hasPendingCreation == true }

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
        buffer.replyWaitLimit = replyWaitLimit
        buffer.onBound = { [weak self, weak window] buffer, bound in // a bound ends the hold; the reply bound's keys go on in order (m12)
            guard let self, buffers[number] === buffer else { return }
            guard let window else { return endClosed(buffer, window: number) } // the window is gone
            if bound == .reply, case let state = router?.focus(for: window).0?.focus.currentState() { buffer.endReplyWait(personMoves: state?.personMoveSeq, shows: { tab in state?.topology.panes.contains { $0.selected == tab } == true }); claims.end(inWindow: number) }
            flush(in: window, force: true, end: bound == .reply ? .replyBoundReached : .limitReached)
        }
        buffer.expire(after: holdLimit)
        return buffer
    }

    /// The hold's window is gone: each key held for a terminal goes to it (m12); a key for no terminal goes with the window.
    private func endClosed(_ buffer: CreationInputBuffer, window number: Int) {
        (buffers[number], _) = (nil, holdEnds.windowClosed(number))
        buffer.takeForClosedWindow(window: number).forEach { type($0.0, into: $0.1) }
    }

    /// The creation behind `ticket` got its reply (`landed`: its focus was asked for) or failed.
    /// The keys go on in a new main-actor turn: outside the creation's task (its action scope)
    /// and after the focus events the reply queued.
    /// `workspace`: the workspace a ``beginWorkspace(in:)`` create made (nil: none, and the keys typed for it go with it).
    func resolve(_ ticket: CreationInputBuffer.Ticket?, landed: Bool, workspace: String? = nil, in window: NSWindow?) {
        if let window, let workspace, let ticket { claims.made(workspace, by: ticket, in: window); _ = claimHolds(in: window) }
        guard let ticket, let window, let buffer = buffers[window.windowNumber], buffer.owns(ticket) else { return } // a reply after its hold ended
        if !landed { holdEnds.creationFailed(in: window.windowNumber) }
        buffer.resolve(ticket, awaitsFocus: landed, workspace: workspace)
        scheduleFlush(in: window)
        // The focus it asked for may never land (a split from a page tab shows a New Tab page):
        // the keys go on `holdLimit` after the reply at the latest.
        buffer.expire(after: holdLimit)
    }

    /// A person's close of `tabs` waits for an answer (the close warning's read): when it takes the focused live terminal (never a cancelled stand-in), or while that terminal's close reads, the tab its pane selects now (a quick second Cmd-W), keys typed meanwhile are the close's (P0 close-then-type). Another terminal's close (its close button) opens no lane: its Cancel must never type them into it.
    /// `hides`: the close takes its tabs out of the strip while it reads, so every key typed in the window meanwhile is
    /// the close's, whatever the focus moved to (`CreationInputBuffer.openClose(closing:machine:takesEveryKey:)`).
    func beginClose(of tabs: [TabModel], in window: NSWindow?, hides: Bool = false) -> CreationInputBuffer.Ticket? {
        let live = tabs.filter(\.isLiveTerminal).map(\.id)
        guard let window, ActionRunScope.viewChangeAllowed(), let controller = router?.focus(for: window).0, let focused = controller.focus.state.terminalTab, !live.isEmpty,
              live.contains(focused) || buffers[window.windowNumber]?.isClosing(tab: focused) == true && controller.focus.state.resolved.pane.flatMap({ controller.content?.paneController(key: $0)?.stripModel.selectedID?.rawValue }).map(live.contains) == true else { return nil }
        return buffer(in: window).openClose(closing: live.contains(focused) ? [focused] + live.filter { $0 != focused } : live,
                                            machine: controller.content?.daemon.machineID, takesEveryKey: hides)
    }

    /// How many close questions are up, by window: a key typed meanwhile is the question's, and the held keys wait, in typing order, for the last answer.
    private var asking: [Int: Int] = [:]

    /// The close asks the person: its keys wait in the window's hold for the answer, and the question takes the keys typed now.
    func parkClose(_ ticket: CreationInputBuffer.Ticket?, in window: NSWindow?) -> CreationInputBuffer.ParkedClose? {
        guard let window else { return nil }
        asking[window.windowNumber, default: 0] += 1
        if let ticket { buffers[window.windowNumber]?.parkClose(ticket) }
        return .init(ticket: ticket)
    }

    /// The close ran: its keys go to the terminal focused now, once it has the keyboard. The person answered its question
    /// (`parked`), with Cancel (`stays`): its keys go to the terminal it asked about, wherever the focus is. Either way they go
    /// in typing order with the window's other held keys, after the last open question's answer (``flush(in:force:end:)``).
    func endClose(_ ticket: CreationInputBuffer.Ticket?, parked: CreationInputBuffer.ParkedClose? = nil, stays: Bool = false, in window: NSWindow?) {
        guard let window else { return }
        let number = window.windowNumber, controller = router?.focus(for: window).0
        if parked != nil { asking[number] = asking[number].flatMap { $0 > 1 ? $0 - 1 : nil }; scheduleFlush(in: window) }
        guard let ticket = ticket ?? parked?.ticket else { return }
        buffers[number]?.settleClose(ticket, keysTo: controller?.focus.state.terminalTab, stays: stays, machine: controller?.content?.daemon.machineID)
        resolve(ticket, landed: controller != nil, in: window)
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
        guard let router, let window else { return false }
        let (controller, kind) = router.focus(for: window)
        // A Chromium page window is a child of the shell, whose number keys the buffer.
        let shell = controller?.window ?? window
        // A held key runs again: never captured twice; a person's claim still keeps one typed for no terminal from the window.
        if replaying.on { return !replaying.lane && kind == .content && keepsFromWindow(event, in: shell) }
        if asking[shell.windowNumber] != nil { return false } // a close's question is up: a key typed now is its own, the held keys wait for its answer
        // The focus names a terminal whose surface is not shown yet (a reopened window, a workspace shown
        // cold): the key waits for it, at most `holdLimit`, and goes to that terminal (REOPEN-F4); a second one gets its own lane.
        if buffers[shell.windowNumber].map({ $0.awaitedTab != nil || $0.personLeftEveryCreation }) ?? true, kind == .content, let controller, ActionRunScope.viewChangeAllowed(),
           let awaited = Self.awaitedContent(controller), buffers[shell.windowNumber]?.awaitedTab != awaited.tab, awaited.hasTerminalLane || !holdEnds.pageExpired.contains(awaited.tab) {
            buffer(in: shell).awaitContent(awaited, machine: controller.content?.daemon.machineID)
        }
        // No hold: a person's keyboard claim still keeps a key from the window (the terminal it was typed for never showed).
        guard let buffer = buffers[shell.windowNumber] else { return kind == .content && keepsFromWindow(event, in: shell) }
        // A key typed while the person's new workspace's terminal is on its way and they have not moved on is that terminal's.
        // Automation's focus move (a new generation) does not take the key from it: the claim decides first.
        let forNewWorkspace = claimHolds(in: shell) || controller.map { buffer.newestGeneration == $0.focus.state.generation } ?? false
        if kind == .content, let controller, buffer.passesOn(focusedTab: controller.focus.state.typingTab), Self.responderTakesKeys(controller, window: shell) { return false } // moved on
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
        // A close key while a close of the focused terminal (or a hidden close) still reads: it acts now, and the held keys
        // keep waiting (flushed, they ran into the closing terminal or the neighbour, #29409).
        if closes, buffer.isClosing(tab: controller?.focus.state.terminalTab) { return false }
        // Focus left the content (a sidebar or bar field) or the hold lets this key go: the held
        // keys go on first, then this one (into a hold a replayed key opened, if it keeps it). A surface hold keeps a chord no app shortcut takes (Ctrl-C).
        // A page hold keeps every key but a close (Cmd-L needs the page), until its bound.
        guard kind == .content, let focused = controller, (!closes && buffer.awaitsPage && ContinuousClock.now - buffer.began < holdLimit && AwaitedContent.pageHoldKeeps(isChord: KeyRouter.isChord(event.modifierFlags), holdIsEmpty: buffer.isEmpty, command: router.resolve(event, context: router.keyContext(for: focused.focus.currentState(), facts: router.facts(in: shell, controller: focused)))?.command.rawValue, pageCreated: router.focusedBrowserTab(in: focused)?.pageCreated ?? false)) || (!closes && KeyRouter.isChord(event.modifierFlags) && buffer.awaitedTab.map { shortcut(event, tab: $0, in: shell) == nil } == true) || buffer.holds(event, limit: holdLimit, expiring: true, closes: closes) else {
            if buffer.waitedPastReplyBound() { buffer.onBound?(buffer, .reply) } else { flush(in: shell, force: true, end: .focusLeft) }
            guard let next = buffers[shell.windowNumber] else { return kind == .content && keepsFromWindow(event, in: shell) }
            guard next.holds(event, limit: holdLimit, expiring: false, closes: closes) else { return false }
            next.capture(event, focusedTab: controller?.focus.state.typingTab)
            return true
        }
        // A pending creation's early view has the keyboard: the keys held for it first, then this one if it was typed for
        // it too. Keys typed for another creation wait for that one's terminal (P0 1193).
        if let controller, let lane = Self.keyboardTerminal(controller, shell).flatMap(buffer.earlyLane(tab:)), runAgain(buffer.take(lane: lane), from: buffer, in: shell),
           lane == buffer.lane(focusedTab: controller.focus.state.typingTab) { return false }
        buffer.capture(event, focusedTab: controller?.focus.state.typingTab, forNewWorkspace: forNewWorkspace)
        return true
    }

    /// Runs held `keys` of `window` again in order, each for its own terminal, never the focused one in its place. False
    /// when one started another creation (a new hold, or another in `buffer`): the rest wait for it, in order.
    private func runAgain(_ keys: [CreationInputBuffer.HeldKey], from buffer: CreationInputBuffer, in window: NSWindow) -> Bool {
        let opened = buffer.openedCount
        for (index, key) in keys.enumerated() {
            replaying = (true, key.lane != nil)
            switch key {
            case .run(let event, _): if let router { replay(event, window, router) }
            case .type(let events, let lane): type(events, into: lane)
            case .command(let event, let lane): // with that terminal's tab as its target; no binding now: its key
                guard let (binding, context) = shortcut(event, tab: lane.tab, in: window), let router else { type([event], into: lane); break }
                RegistryKeyBindings(router.registry).run(binding, keyContext: context.bits, target: ActionTargetRef(kind: .tab, id: lane.tab))
            }
            replaying = (false, false)
            if let next = buffers[window.windowNumber], next !== buffer || next.openedCount != opened {
                next.prepend(keys.dropFirst(index + 1).flatMap(\.keys), issuer: key.lane)
                return false
            }
        }
        return true
    }

    /// Types `events` into `lane`'s terminal with its own key encoding: its view's (also hidden), else, its view gone, the
    /// daemon's (that terminal's modes; another machine's terminal too). A closed terminal takes its keys with it.
    private func type(_ events: [NSEvent], into lane: CreationInputBuffer.HeldLane) {
        guard let services = router?.services else { return }
        if let view = services.cache.existingTerminal(lane.tab)?.session.surfaceView { return events.forEach(view.typeHeldKey) }
        guard let machine = lane.machine, let (tab, pane) = services.locateTab(lane.tab, onMachine: machine), tab.kind == .pty else {
            return Self.logger.notice("\(events.count, privacy: .public) held key(s) went with their closed terminal")
        }
        let (inputs, skipped) = HeldKeyInput.inputs(for: events, optionAsAlt: GhosttyRuntime.shared.optionAsAltValue), surface = tab.surface
        if skipped > 0 { Self.logger.error("\(skipped, privacy: .public) held key(s) have no daemon key name") }
        services.daemon(for: pane).sendInOrder("send-key", to: surface) { connection in // after this terminal's earlier held sends
            for input in inputs {
                switch input {
                case .text(let text): try await connection.send(surface, text: text)
                case .key(let key): try await connection.sendKeys(surface, [key])
                }
            }
        }
    }

    /// The app shortcut `event` runs in terminal `tab`'s key context, as a key press there; nil: the key is the terminal's.
    private func shortcut(_ event: NSEvent, tab: String, in window: NSWindow) -> (KeyBinding, KeyContext)? {
        guard let router, let controller = router.focus(for: window).0 else { return nil }
        var state = controller.focus.currentState()
        if let pane = controller.content?.panes.values.first(where: { $0.currentTabKey == tab }) { state.resolved = .terminal(pane: pane.paneKey, tab: tab) }
        let context = router.keyContext(for: state, facts: router.facts(in: window, controller: controller))
        return router.resolve(event, context: context).map { ($0, context) }
    }

    /// The focused terminal's tab when its shown view has the keyboard (never another view: a composer, a text field).
    private static func keyboardTerminal(_ controller: WindowController, _ window: NSWindow) -> String? {
        guard case .terminal(let pane, let tab) = controller.focus.state.resolved, let shown = controller.content?.paneController(key: pane),
              shown.currentTabKey == tab, case .terminal(let entry)? = shown.currentContent else { return nil }
        return entry.session.hasKeyboard(window.firstResponder) ? tab : nil
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

    /// `key`'s page arrived or Chromium created its browser: a hold that awaited it ends now (reopen-browser-plain-keys cycle B).
    func pageArrived(_ key: String) { holdEnds.pageArrived(key); router?.services?.windows.controllers.compactMap(\.window).filter { buffers[$0.windowNumber]?.awaitedTab == key }.forEach(scheduleFlush) }

    /// A focus settle in `window`: the keys may go on (in a new turn, after the focus queue).
    func focusDidSettle(in window: NSWindow?) {
        giveBack()
        if let window { _ = claimHolds(in: window) } // a claim whose workspace shows ends now, not at a later key
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
    /// `end`: why a forced end happened (``CreationHoldLog/end(in:forced:)``).
    private func flush(in window: NSWindow, force: Bool = false, end forcedEnd: CreationHoldEnd = .limitReached) {
        guard let buffer = buffers[window.windowNumber], asking[window.windowNumber] == nil else { return } // a close's question is up: the keys wait for its answer, never typed into it (a Return would press Close)
        guard force || buffer.isResolved else {
            // Before every reply, only a creation whose early view has the keyboard takes its own keys (a focus settle).
            if let lane = router?.focus(for: window).0.flatMap({ Self.keyboardTerminal($0, window).flatMap(buffer.earlyLane(tab:)) }) { _ = runAgain(buffer.take(lane: lane), from: buffer, in: window) }
            return
        }
        guard let router, let controller = router.focus(for: window).0 else { return endClosed(buffer, window: window.windowNumber) }
        // Reduced: a topology the window marked changed counts (the new workspace may show in this turn).
        let shown = controller.focus.currentState().topology.workspace
        if !force {
            let focus = controller.focus.state
            if let expectation = focus.expectation, buffer.awaits(expectation.generation) { return }
            let terminal = Self.keyboardTerminal(controller, window) // a new workspace's keys wait for it to show with its terminal (a left one's: its own)
            if let workspace = buffer.shownWorkspaceToWaitFor, workspace != shown || terminal == nil { return }
            guard Self.responderTakesKeys(controller, window: window) else { return }
            if let awaited = buffer.awaitedTab, Self.awaitedContent(controller)?.tab == awaited { return } // its surface comes on a later frame
            if let kept = buffer.keysKeptForLeftWorkspace(shown: shown, terminalReady: terminal != nil) { return _ = runAgain(buffer.take(focused: terminal, keeping: kept) { self.shortcut($0, tab: $1, in: window) != nil }, from: buffer, in: window) }
        }
        buffers[window.windowNumber] = nil
        // A forced end drops the keys of a new workspace the window does not show, or the focus still waits: it applies again.
        if buffer.dropKeys(ofWorkspacesOtherThan: shown) || controller.focus.state.awaitsOtherTab, let pane = controller.focus.state.pane { controller.focus.send(.contentPresented(pane: pane)) }
        let daemon = controller.content?.daemon
        if buffer.awaitedWorkspace == shown, let daemon { buffer.bindNewWorkspaceKeys(to: shown.flatMap(daemon.store.firstTerminalTab(ofWorkspace:))?.id, machine: daemon.machineID) }
        let end = holdEnds.end(in: window.windowNumber, forced: force ? forcedEnd : nil, pageTab: buffer.awaitsPage ? buffer.awaitedTab : nil)
        let pending = buffer.take(focused: Self.keyboardTerminal(controller, window)) { self.shortcut($0, tab: $1, in: window) != nil }
        CreationHoldLog.noteEnded(end, window: window.windowNumber, keys: pending.count, lastAction: router.lastInterception?.action.rawValue, untyped: buffer.untypedTerminalKeys)
        _ = runAgain(pending, from: buffer, in: window)
    }
}

extension CreationInputCoordinator {
    /// The focused content a key typed now would miss (``AwaitedContent``): a terminal whose surface is not shown in its
    /// pane yet, or a browser tab whose page is not made yet (a restored Chromium tab starts after the window shows).
    static func awaitedContent(_ controller: WindowController) -> AwaitedContent? {
        let state = controller.focus.currentState()
        guard case let (pane, tab, isPage)? = state.awaitableContent, let content = controller.content, content.workspace.id == state.topology.workspace else { return nil }
        let shown = content.paneController(key: pane).map { shown in
            AwaitedContent.Pane(selectedTab: shown.stripModel.selectedID?.rawValue, shownTab: shown.currentTabKey, shownKind: shown.currentContent.flatMap { if case .terminal = $0 { .terminal } else if case .browser = $0 { .browser } else { nil } }, selectedIsLiveTerminal: shown.showsLiveTerminal, shownPageReady: shown.currentContent.flatMap { if case .browser(let entry) = $0 { entry.tab.pageReady } else { nil } } ?? true)
        }
        return AwaitedContent.awaited(isPage ? .browser : .terminal, tab: tab, pane: shown, paneInTopology: state.topology.panes.contains { $0.id == pane })
    }

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
        return entry.session.hasKeyboard(responder) || !(responder is TerminalSurfaceView)
    }
}
