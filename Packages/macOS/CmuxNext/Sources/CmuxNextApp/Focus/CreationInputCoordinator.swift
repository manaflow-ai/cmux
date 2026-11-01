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
@MainActor
final class CreationInputCoordinator {
    weak var router: KeyRouter?
    private var buffers: [Int: CreationInputBuffer] = [:]
    /// Set while a captured key runs again, so it is not captured a second time.
    private var replaying = false
    /// The longest a key waits for a selected terminal's surface (the slowest takes about 350 ms).
    var holdLimit: Duration = .seconds(2)
    private let replay: HeldKeyReplay // a held key runs again (``HeldKeyReplay``)

    /// How each window's creation holds ended (``CreationHoldEnd``, R-L5: its end is a signal).
    private(set) var holdEnds = CreationHoldLog()

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "focus.creation-hold")

    /// How `window`'s last creation hold ended; nil when it never held.
    func lastHoldEnd(in window: NSWindow?) -> CreationHoldEnd? { window.flatMap { holdEnds.last[$0.windowNumber] } }

    /// Whether `window`'s keys wait in a creation hold now (tests: a key typed meanwhile is replayed later).
    func isHolding(in window: NSWindow?) -> Bool { window.map { buffers[$0.windowNumber] != nil } ?? false }

    init(router: KeyRouter, replay: @escaping HeldKeyReplay) { (self.router, self.replay) = (router, replay) }

    /// Opens the window's buffer for one creation that moves focus under the user intent
    /// `generation`; nil without a window, or when the creation may not move focus (a CLI,
    /// script or agent run without `focus`), which leaves the keys where they are.
    func begin(in window: NSWindow?, generation: UInt64?, earlyTab: String? = nil, tab: String? = nil, machine: String? = nil) -> CreationInputBuffer.Ticket? {
        guard let window, let generation, ActionRunScope.viewChangeAllowed() else { return nil }
        return buffer(in: window).open(generation: generation, earlyTab: earlyTab, tab: tab, machine: machine ?? router?.focus(for: window).0?.content?.daemon.machineID)
    }

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
        guard let ticket, let window, let buffer = buffers[window.windowNumber] else { return }
        if !landed { holdEnds.creationFailed(in: window.windowNumber) }
        buffer.resolve(ticket, awaitsFocus: landed)
        scheduleFlush(in: window)
        // The focus it asked for may never land (a split from a page tab shows a New Tab page):
        // the keys go on `holdLimit` after the reply at the latest.
        let number = window.windowNumber
        buffer.expire(after: holdLimit) { [weak self, weak window] buffer in
            guard let self, buffers[number] === buffer else { return }
            if let window { flush(in: window, force: true, end: .limitReached) } else { buffers[number] = nil }
        }
    }

    /// A person's close of `tabs` waits for an answer (the close warning's read): when it takes the focused live terminal (never a cancelled stand-in), or comes while that terminal's close still reads (two quick Cmd-Ws), keys typed meanwhile are the close's (P0 close-then-type).
    func beginClose(of tabs: [TabModel], in window: NSWindow?) -> CreationInputBuffer.Ticket? {
        let live = tabs.filter(\.isLiveTerminal).map(\.id)
        guard let window, ActionRunScope.viewChangeAllowed(), let controller = router?.focus(for: window).0, let focused = controller.focus.state.terminalTab, !live.isEmpty,
              live.contains(focused) || buffers[window.windowNumber]?.isClosing(tab: focused) == true else { return nil }
        return buffer(in: window).openClose(closing: live.contains(focused) ? [focused] + live.filter { $0 != focused } : live, machine: controller.content?.daemon.machineID)
    }

    /// Keys of closes that ended while a close's question was up, by window: they wait for its answer with its own keys.
    private var asking: [Int: [NSEvent]] = [:]

    /// The close asks the person: its keys wait for the answer outside the hold (the question takes its own keys).
    func parkClose(_ ticket: CreationInputBuffer.Ticket?, in window: NSWindow?) -> CreationInputBuffer.ParkedClose? {
        guard let window else { return nil }
        if asking[window.windowNumber] == nil { asking[window.windowNumber] = [] }
        guard let ticket, let parked = buffers[window.windowNumber]?.parkClose(ticket) else { return .init(events: [], closing: "", machine: nil) }
        scheduleFlush(in: window)
        return parked
    }

    /// The close ran: its keys (`parked` first) go to the terminal focused now, once it has the keyboard. The person
    /// cancelled it (`stays`): its parked keys go to the terminal that stays now, by that terminal, wherever the focus is.
    /// A close that ends while another close's question is up waits for that answer; a gone window takes its keys with it.
    func endClose(_ ticket: CreationInputBuffer.Ticket?, parked: CreationInputBuffer.ParkedClose? = nil, stays: Bool = false, in window: NSWindow?) {
        guard let window else { return }
        let number = window.windowNumber
        if parked == nil, asking[number] != nil {
            if let ticket, let more = buffers[number]?.parkClose(ticket) { asking[number]?.append(contentsOf: more.events); scheduleFlush(in: window) }
            return
        }
        let parked = parked.map { CreationInputBuffer.ParkedClose(events: $0.events + (asking.removeValue(forKey: number) ?? []), closing: $0.closing, machine: $0.machine) }
        if stays, let parked, !parked.closing.isEmpty, !parked.events.isEmpty {
            let lane = CreationInputBuffer.HeldLane(tab: parked.closing, machine: parked.machine)
            return _ = runAgain(CreationInputBuffer.heldKeys(parked.events, for: lane), from: buffers[number] ?? CreationInputBuffer(began: ContinuousClock.now), in: window)
        }
        let controller = router?.focus(for: window).0
        guard let ticket = ticket ?? parked.flatMap({ $0.events.isEmpty ? nil : buffer(in: window).openClose(closing: [$0.closing], machine: $0.machine) }) else { return }
        buffers[number]?.settleClose(ticket, parked: parked, keysTo: controller?.focus.state.terminalTab, machine: controller?.content?.daemon.machineID)
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
        // A close key while a close of the focused terminal still reads (two quick Cmd-Ws): it acts now, and the held keys
        // keep waiting (flushed, they ran into the closing terminal).
        if closes, let tab = controller?.focus.state.terminalTab, buffer.isClosing(tab: tab) { return false }
        // Focus left the content (a sidebar or bar field) or the hold lets this key go: the held
        // keys go on first, then this one (into a hold a replayed key opened, if it keeps it).
        guard kind == .content, controller != nil, buffer.holds(event, limit: holdLimit, expiring: true, closes: closes) else {
            flush(in: shell, force: true, end: .focusLeft)
            guard let next = buffers[shell.windowNumber], next.holds(event, limit: holdLimit, expiring: false, closes: closes) else { return false }
            next.capture(event, focusedTab: controller?.focus.state.typingTab)
            return true
        }
        // A pending creation's early view has the keyboard: the keys held for it first, then this one if it was typed for
        // it too. Keys typed for another creation wait for that one's terminal (P0 1193).
        if let controller, let lane = Self.keyboardTerminal(controller, shell).flatMap(buffer.earlyLane(tab:)), runAgain(buffer.take(lane: lane), from: buffer, in: shell),
           lane == buffer.lane(focusedTab: controller.focus.state.typingTab) { return false }
        buffer.capture(event, focusedTab: controller?.focus.state.typingTab)
        return true
    }

    /// Runs held `keys` of `window` again in order, each for its own terminal, never the focused one in its place. False
    /// when one started another creation (a new hold, or another in `buffer`): the rest wait for it, in order.
    private func runAgain(_ keys: [CreationInputBuffer.HeldKey], from buffer: CreationInputBuffer, in window: NSWindow) -> Bool {
        let opened = buffer.openedCount
        for (index, key) in keys.enumerated() {
            replaying = true
            switch key {
            case .run(let event, _): if let router { replay(event, window, router) }
            case .type(let events, let lane): type(events, into: lane)
            case .command(let event, let lane): // with that terminal's tab as its target; no binding now: its key
                guard let (binding, context) = shortcut(event, tab: lane.tab, in: window), let router else { type([event], into: lane); break }
                RegistryKeyBindings(router.registry).run(binding, keyContext: context.bits, target: ActionTargetRef(kind: .tab, id: lane.tab))
            }
            replaying = false
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
    /// `end`: why a forced end happened (``CreationHoldLog/end(in:forced:)``).
    private func flush(in window: NSWindow, force: Bool = false, end forcedEnd: CreationHoldEnd = .limitReached) {
        guard let buffer = buffers[window.windowNumber] else { return }
        guard force || buffer.isResolved else {
            // Before every reply, only a creation whose early view has the keyboard takes its own keys (a focus settle).
            if let lane = router?.focus(for: window).0.flatMap({ Self.keyboardTerminal($0, window).flatMap(buffer.earlyLane(tab:)) }) { _ = runAgain(buffer.take(lane: lane), from: buffer, in: window) }
            return
        }
        guard let router, let controller = router.focus(for: window).0 else {
            // The window is gone: its keys go with it.
            buffers[window.windowNumber] = nil
            holdEnds.windowClosed(window.windowNumber)
            return
        }
        if !force {
            let focus = controller.focus.state
            if let expectation = focus.expectation, buffer.awaits(expectation.generation) { return }
            guard Self.responderTakesKeys(controller, window: window) else { return }
        }
        buffers[window.windowNumber] = nil
        let end = holdEnds.end(in: window.windowNumber, forced: force ? forcedEnd : nil)
        let pending = buffer.take(focused: Self.keyboardTerminal(controller, window)) { self.shortcut($0, tab: $1, in: window) != nil }
        if end == .limitReached {
            // The person's keys for a new terminal waited the whole bound and go on now, each to the terminal it was typed for.
            Self.logger.notice("creation hold of window \(window.windowNumber, privacy: .public) ended at its limit, not on focus: \(pending.count, privacy: .public) held key(s) go on now; last action \(router.lastInterception?.action.rawValue ?? "-", privacy: .public)")
        }
        _ = runAgain(pending, from: buffer, in: window)
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
        return entry.session.hasKeyboard(responder) || !(responder is TerminalSurfaceView)
    }
}
