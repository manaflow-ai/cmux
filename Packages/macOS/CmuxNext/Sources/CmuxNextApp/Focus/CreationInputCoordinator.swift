import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextFocus
import CmuxNextFocusUI
import CmuxNextTerminal

/// Owns a window's keys from the moment a pane or terminal tab creation is handled (a split, New Terminal Tab, a new
/// workspace with its terminal) until the new terminal has the keyboard (cx-wb5.76), and while a selected terminal tab
/// has no surface yet (Ctrl-1…9 onto a cold tab, hq#1925 item 3). Without it, keys typed right after Cmd-D or Ctrl-` went
/// to the old pane or tab: focus moves to the new one only after the reply, and the optimistic split's swap to the
/// daemon's pane remounts its view.
///
/// The keys wait in the window's one ``WindowInputQueue`` (principled audit, lagFirstKey), each stamped with the target it
/// was typed for: the newest creation's tab (a stand-in id until its focus lands on a tab), or the cold tab. Release is
/// level-triggered (``reconcile(_:)``, on each key, each focus settle, each reply): a target's keys go, in typed order,
/// when the focus model names that target and its view has the keyboard (``responderTakesKeys(_:window:)``), and run
/// again through `NSApplication.sendEvent`, as typed (the key router, key equivalents and the menu included). A target
/// that closes or fails, or that the person's newer intent moved the focus away from, drops its keys with a logged
/// reason; they never go to another target. No timer decides where or whether a key goes, and the queue goes with its
/// window. Only input for the target waits: an app command (a key bound to a cmux action, a menu key equivalent, Escape)
/// acts on the model at once (``heldKeyKind(_:in:controller:router:)``), and Escape ends the wait. A held key whose run
/// makes another target (a key a terminal binds) takes the keys typed after it to that target, as the person typed them.
///
/// Invariant (HK1, checked after every change in DEBUG and by the input invariant monitor): captured == delivered +
/// dropped + waiting, each target's keys in typed order, never delivered to another target.
///
/// The person's new workspace with a terminal (`newTab` shown in this window, `beginWorkspace`) also claims the window's
/// keyboard (`KeyboardClaim`) until the person's next intent there: a click, Escape, a focus move of theirs (mouse,
/// keyboard, palette), another of their actions; or until the window shows it. Never by a timeout, and never by
/// automation (a script's focus move or intent). After the hold, every key that runs no binding is still kept from the
/// window. While a claim or a creation the person has not moved on from holds a window's keys, no primary input takes
/// that window's keyboard by itself (``claimsKeyboard(in:generation:)``). Dogfood v2.2.3: Home's Chief message box took
/// the keys typed for a new terminal and sent a shell command to the Chief as a message; terminal input must never reach
/// an agent.
@MainActor
final class CreationInputCoordinator {
    weak var router: KeyRouter?
    /// Each window's held keys and the creations they wait for, by window number, freed with the window.
    private var holds: [Int: WindowHold] = [:]
    /// The person's new terminal's claim on a window's keyboard, by window number (``beginWorkspace(in:)``).
    private var claims: [Int: KeyboardClaim] = [:] { didSet { syncMode() } }
    /// Set while a captured key runs again, so it is not captured a second time.
    private var replaying = false
    /// Held keys run again since launch (tests: a key must never be run into a view it was not typed for).
    private(set) var replayedCount = 0

    init(router: KeyRouter) { self.router = router }

    /// One window's held keys: its queue, the creations they wait for, and the target keys typed now are for.
    @MainActor
    private final class WindowHold {
        /// The window's one queue (``KeyRouter/inputQueues``); this hold's targets are the ones that are not a New Tab
        /// page's.
        let queue: WindowInputQueue
        let creations = CreationInputBuffer()
        /// The target a key typed now is for (the newest creation's, or the cold tab's), with the generation of the
        /// person's intent that made it.
        var current: (target: WindowInputQueue.Target, generation: UInt64)?
        /// A selected terminal tab whose surface comes later (Ctrl-1…9 onto a cold tab).
        var shown: WindowInputQueue.Target?
        /// The generation of the intent each waiting target's keys were typed under.
        var generations: [WindowInputQueue.Target: UInt64] = [:]
        /// Where each landed creation's focus expectation lands (`tab:<id>` or `surface:<id>`), seen while it was pending:
        /// its keys follow it there.
        var landsOn: [WindowInputQueue.Target: String] = [:]
        var scheduled = false
        var reconciling = false

        init(queue: WindowInputQueue) { self.queue = queue }

        /// Keys of this hold wait (not a New Tab page's).
        var holdsKeys: Bool { queue.targets.contains { !$0.isNewTabPage } }

        /// It holds keys, waits for a creation or a surface, or makes the keys typed now wait.
        var isActive: Bool { holdsKeys || !creations.isEmpty || current != nil }
    }

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
    private func syncMode() {
        router?.modes.set(.creationCapture, holds.values.contains(where: \.isActive) || claims.values.contains { $0.window != nil })
    }

    /// `window` closed: its claim goes with it, and its held keys drop (``WindowInputQueue/close()``).
    func windowClosed(_ window: NSWindow?) {
        guard let window else { return }
        claims[window.windowNumber] = nil
        holds[window.windowNumber] = nil
        router?.inputQueues.close(window.windowNumber)
        router?.newTabInputCoordinator.windowClosed(window)
        syncMode()
    }

    /// The person acted in `window` (a click after its dispatch, a focus move of theirs, one of their actions), answering
    /// input `event`: a claim there ends, and the keys go where they put them. The input that asked for the claim (the
    /// click or key of New Workspace) does not end it.
    func personActed(in window: NSWindow?, event: NSEvent?) {
        router?.newTabInputCoordinator.personActed(in: window)
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

    /// Opens a creation in `window` that moves focus under the user intent `generation`: the keys typed from now on are
    /// its keys. Nil without a window, or when the creation may not move focus (a CLI, script or agent run without
    /// `focus`), which leaves the keys where they are. `earlyTab`: its new terminal's view takes keys before the reply
    /// (cx-wb5.78). `tab`: the provisional tab it shows (a close of it drops its keys).
    func begin(in window: NSWindow?, generation: UInt64?, earlyTab: String? = nil, tab: String? = nil) -> CreationInputBuffer.Ticket? {
        guard let window, let generation, ActionRunScope.viewChangeAllowed() else { return nil }
        return open(in: window, generation: generation) { $0.open(generation: generation, earlyTab: earlyTab, tab: tab) }
    }

    /// Opens a creation of a new workspace with a terminal that `window` will show (`newTab` with focus), under a new user
    /// intent of that window's focus; nil when the run may not move focus. Resolve it with ``resolve(_:workspace:in:)``.
    func beginWorkspace(in controller: WindowController?) -> CreationInputBuffer.Ticket? {
        guard let controller, let window = controller.window, ActionRunScope.viewChangeAllowed() else { return nil }
        let generation = controller.focus.beginIntent()
        let input = router?.registry.dispatchingInputEvent()
        let claim = KeyboardClaim(generation: generation, window: window, inputTimestamp: input?.timestamp)
        claims[window.windowNumber] = claim
        let ticket = open(in: window, generation: generation) { $0.open(generation: generation, newWorkspace: true) }
        claim.ticket = ticket
        return ticket
    }

    private func open(in window: NSWindow, generation: UInt64, _ make: (CreationInputBuffer) -> CreationInputBuffer.Ticket) -> CreationInputBuffer.Ticket {
        let hold = hold(in: window)
        let ticket = make(hold.creations)
        if let target = hold.creations.creation(ticket)?.target {
            hold.current = (target, generation)
            hold.generations[target] = generation
        }
        syncMode()
        return ticket
    }

    private func hold(in window: NSWindow) -> WindowHold {
        if let hold = holds[window.windowNumber] { return hold }
        let hold = WindowHold(queue: router?.inputQueues.queue(for: window.windowNumber) ?? WindowInputQueue())
        holds[window.windowNumber] = hold
        return hold
    }

    /// Whether a creation in `window` that the person has not moved on from (no user intent since it was asked for)
    /// holds its keys: the keyboard is that creation's, so a primary input (Home's message box) does not take it by
    /// itself (`NSWindow.pendingCreationOwnsKeyboard`).
    func claimsKeyboard(in window: NSWindow, generation: UInt64) -> Bool {
        if activeClaim(in: window) != nil { return true }
        guard let newest = holds[window.windowNumber]?.creations.newest else { return false }
        return newest.generation == generation
    }

    /// Whether `window` has a claim recorded now, ended or not (tests, `debug.focus`).
    func hasClaim(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return claims[window.windowNumber] != nil
    }

    /// What `window`'s hold waits for now (tests' failure reports).
    func earlyDeliveryState(in window: NSWindow) -> String {
        guard let hold = holds[window.windowNumber] else { return "no hold" }
        guard let controller = router?.focus(for: window).0 else { return "no controller" }
        let state = controller.focus.state
        let named = state.resolved.tab.map(WindowInputQueue.Target.init)
        return "waiting \(hold.queue.targets.map { "\($0)=\(hold.queue.waiting(for: $0))" }), current \(hold.current.map { "\($0.target)@\($0.generation)" } ?? "-"), "
            + "creations \(hold.creations.all.map { "\($0.creation.target)@\($0.creation.generation) landed \($0.creation.landed)" }), "
            + "focus \(state.resolved)@\(state.generation), takes keys \(named.map { takesKeys($0, hold: hold, controller: controller, window: window) } ?? false), "
            + "counts \(hold.queue.counts)"
    }

    /// How many keys `window`'s hold keeps now (tests).
    func heldCount(in window: NSWindow?) -> Int {
        guard let window else { return 0 }
        return holds[window.windowNumber]?.queue.count ?? 0
    }

    /// Whether `window`'s keys wait in a creation hold now (tests, `debug.focus`).
    func isHolding(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return holds[window.windowNumber]?.isActive ?? false
    }

    /// The broken parts of every window's held-key invariant (HK1), empty when it holds (the input invariant monitor).
    func heldKeyProblems() -> [String] { router?.inputQueues.problems ?? [] }

    /// The person closed provisional tab `tab` in `window` before the daemon made it: the keys typed for it drop, the
    /// rest go on.
    func drop(tab: String, in window: NSWindow?) {
        guard let window, let hold = holds[window.windowNumber] else { return }
        drop(hold.creations.cancel(tab: tab), .targetClosed, in: hold)
        syncMode()
        scheduleReconcile(in: window)
    }

    private func drop(_ creations: [CreationInputBuffer.Creation], _ reason: WindowInputQueue.DropReason, in hold: WindowHold) {
        for creation in creations {
            hold.queue.drop(creation.target, reason)
            if hold.current?.target == creation.target { hold.current = nil }
        }
    }

    /// The focused pane selected terminal tab `tab`, whose surface comes later: keys typed now wait for it, until its
    /// view has the keyboard or the person moves on.
    func holdUntilShown(tab: String, in window: NSWindow?) {
        guard let window, ActionRunScope.viewChangeAllowed() else { return }
        let hold = hold(in: window)
        let target = WindowInputQueue.Target(tab)
        let generation = router?.focus(for: window).0?.focus.state.generation ?? 0
        hold.shown = target
        hold.current = (target, generation)
        hold.generations[target] = max(hold.generations[target] ?? 0, generation)
        syncMode()
    }

    /// The creation behind `ticket` got its reply (`landed`: its focus was asked for) or failed (its keys drop).
    func resolve(_ ticket: CreationInputBuffer.Ticket?, landed: Bool, in window: NSWindow?) {
        resolve(ticket, landed: landed, workspace: nil, in: window)
    }

    /// The creation behind `ticket` made surface `created`, or failed (nil).
    func resolve(_ ticket: CreationInputBuffer.Ticket?, created: SurfaceID?, in window: NSWindow?) {
        resolve(ticket, landed: created != nil, workspace: nil, in: window)
    }

    /// The new workspace behind `ticket` (``beginWorkspace(in:)``) was made (`workspace`, its id) or not (nil: it
    /// failed or a close took it, and the keys typed for it drop).
    func resolve(_ ticket: CreationInputBuffer.Ticket?, workspace: String?, in window: NSWindow?) {
        resolve(ticket, landed: workspace != nil, workspace: workspace, in: window)
    }

    /// The keys go on in a new main-actor turn: outside the creation's task (its action scope) and after the focus events
    /// the reply queued.
    private func resolve(_ ticket: CreationInputBuffer.Ticket?, landed: Bool, workspace: String?, in window: NSWindow?) {
        if let window, let workspace, let ticket, let claim = claims[window.windowNumber], claim.ticket == ticket {
            claim.workspace = workspace
            _ = activeClaim(in: window) // the window may show it already (its delta came before the reply)
        }
        guard let ticket, let window else { return }
        let hold = holds[window.windowNumber]
        let creation = hold?.creations.resolve(ticket, landed: landed, workspace: workspace)
        if !landed {
            if let hold, let creation { drop([creation], .targetFailed, in: hold) }
            // Also when the hold forgot the creation (Escape ended its wait): the failed target never stays focused.
            settleFocusAfterFailure(in: window)
        }
        guard let hold, let creation else { return }
        // Where its focus lands, read in the reply's turn: the expectation it asked for, or the tab that expectation
        // already landed on (the topology listed it). A new workspace's lands once the window shows it.
        if creation.landed, !creation.newWorkspace, let state = router?.focus(for: window).0?.focus.currentState(),
           state.generation == creation.generation {
            if let expectation = state.expectation, expectation.generation == creation.generation {
                hold.landsOn[creation.target] = Self.landingKey(expectation.key)
            } else if let tab = state.resolved.tab {
                hold.landsOn[creation.target] = "tab:\(tab)"
            }
        }
        syncMode()
        scheduleReconcile(in: window)
    }

    /// R3 at a failed creation (principled audit, lagFirstKey step 6): in the failure's turn the window's content follows
    /// the store (the failed pane or tab is gone from it) and the focus model reduces that topology, so the model names a
    /// target that exists (the close-focus successor) and applies it to the responder. No window keeps a dead keyboard
    /// until a later turn, a timer or the next key.
    private func settleFocusAfterFailure(in window: NSWindow) {
        guard let controller = router?.focus(for: window).0 else { return }
        controller.workspaceContent?.applyCurrent()
        _ = controller.focus.currentState()
    }

    /// What a key typed while keys are held is: a close key, an app command, or input for the target it was typed for.
    enum HeldKeyKind: Equatable {
        /// A close action (Close Tab, Cmd-W): it acts now on what it closes.
        case close
        /// An app command: it acts on the model at once and never waits behind held input.
        case command
        /// Input for the target's view: it waits for that target, in typed order.
        case input
    }

    /// The kind of `event` in `controller`'s focus (review finding 6, lead's decision 4a). App commands are never held:
    /// a key bound to a cmux action (Cmd-T, Cmd-D, Ctrl-Tab, Ctrl-1…9, Cmd-Q), the next key of a pending chord, a menu key
    /// equivalent (Cmd-H, Cmd-M) and Escape act on the model at once, as Chrome runs browser shortcuts before the page.
    /// Input for the target's view waits: text, Return, a terminal's control keys (Ctrl-C), and the Edit menu's responder
    /// keys (Cmd-V, Cmd-C, Cmd-A, Cmd-Z), which act on the view that has the keyboard.
    static func heldKeyKind(_ event: NSEvent, in window: NSWindow, controller: WindowController?, router: KeyRouter) -> HeldKeyKind {
        if event.keyCode == ChordTracker.escapeKeyCode || router.chords.isPending { return .command }
        guard KeyRouter.isChord(event.modifierFlags) else { return .input }
        if let controller {
            let context = router.keyContext(for: controller.focus.currentState(), facts: router.facts(in: window, controller: controller))
            if let binding = router.resolve(event, context: context) { return WindowKeyTable.isClose(binding.command) ? .close : .command }
        }
        guard event.modifierFlags.contains(.command), let item = NSApp.mainMenu.flatMap({ menuItem(for: event, in: $0) }) else { return .input }
        return item.action.map(responderEditActions.contains) == true ? .input : .command
    }

    /// The Edit menu's responder-chain actions (MainMenu): they act on the view that has the keyboard, so their keys are
    /// input for the target the person typed them for.
    private static let responderEditActions: Set<Selector> = [
        Selector(("undo:")), Selector(("redo:")), #selector(NSText.cut(_:)), #selector(NSText.copy(_:)),
        #selector(NSText.paste(_:)), #selector(NSTextView.pasteAsPlainText(_:)), #selector(NSText.selectAll(_:)),
    ]

    /// The enabled-or-not item of `menu` (or its submenus) whose key equivalent `event` types.
    private static func menuItem(for event: NSEvent, in menu: NSMenu) -> NSMenuItem? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let typed = (event.charactersIgnoringModifiers ?? "").lowercased()
        for item in menu.items {
            if let submenu = item.submenu {
                if let found = menuItem(for: event, in: submenu) { return found }
                continue
            }
            guard !item.keyEquivalent.isEmpty, item.keyEquivalent.lowercased() == typed else { continue }
            // An uppercase key equivalent means Shift (AppKit's convention).
            var mask = item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift])
            if item.keyEquivalent != item.keyEquivalent.lowercased() { mask.insert(.shift) }
            if mask == flags { return item }
        }
        return nil
    }

    /// Takes `event` while its window holds keys: it waits, stamped with the target it was typed for, unless nothing waits
    /// for that target and the target has the keyboard (then it goes on now).
    func capture(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard !replaying, let router, let window else { return false }
        let (controller, kind) = router.focus(for: window)
        // A Chromium page window is a child of the shell, whose number keys the hold.
        let shell = controller?.window ?? window
        // A key the window's queue delivers now (this hold's or the New Tab hold's) is never captured again.
        if router.inputQueues.existing(for: shell.windowNumber)?.isDelivering == true { return false }
        guard let hold = holds[shell.windowNumber], hold.isActive else {
            droppedLastKey = kind == .content && keepsFromWindow(event, in: shell)
            return droppedLastKey
        }
        droppedLastKey = false
        let keyKind = Self.heldKeyKind(event, in: shell, controller: controller, router: router)
        // A close key (Cmd-W) never waits: it acts now on what it closes. A close of a pending creation of this window
        // drops the keys typed for it; the others keep waiting for their targets.
        if keyKind == .close, let controller {
            if let tab = Self.creatingTab(of: controller, in: hold.creations) { drop(hold.creations.cancel(tab: tab), .targetClosed, in: hold) }
            reconcile(shell)
            return false
        }
        if controller != nil { reconcile(shell) }
        // A panel, popup or overlay of the window has the keyboard: the key is its. The held keys keep waiting.
        guard kind == .content || controller == nil else { return false }
        // Escape is the person ending the wait (review finding 6): the keys typed for this hold's targets drop, the
        // keys typed next go where the focus is, and a keyboard claim ends (``keepsFromWindow(_:in:)``). Escape itself
        // goes on now.
        if event.keyCode == ChordTracker.escapeKeyCode {
            endWait(hold)
            syncMode()
            return keepsFromWindow(event, in: shell)
        }
        // Any other app command acts on the model at once; it never waits behind held input. The person's intent it
        // runs leaves the targets the held keys were typed for (``reconcile(_:)``).
        if keyKind == .command { return false }
        guard let current = holds[shell.windowNumber]?.current else {
            // As any key after a hold: a person's keyboard claim still keeps it from the window (the Chief's box).
            droppedLastKey = kind == .content && keepsFromWindow(event, in: shell)
            return droppedLastKey
        }
        let target = current.target
        if hold.queue.waiting(for: target) == 0, let controller, takesKeys(target, hold: hold, controller: controller, window: shell) {
            return false
        }
        // A chord passes a cold tab's wait that holds nothing (held Ctrl-Tab makes no surface for a tab it passed).
        if !hold.holdsKeys, hold.creations.isEmpty, hold.shown == target, KeyRouter.isChord(event.modifierFlags) { return false }
        hold.generations[target] = max(hold.generations[target] ?? 0, current.generation)
        hold.queue.capture(event, for: target)
        syncMode()
        return true
    }

    /// The pending creation of `creations` that `controller`'s focus asks for (its expectation) or already names (focus
    /// landed on it before the reply): a close key then closes it, and the keys typed for it go with it.
    private static func creatingTab(of controller: WindowController, in creations: CreationInputBuffer) -> String? {
        let focus = controller.focus.state
        if case .tab(let tab)? = focus.expectation?.key, creations.isCreating(tab: tab) { return tab }
        if case .terminal(_, let tab) = focus.resolved, creations.isCreating(tab: tab) { return tab }
        return nil
    }

    /// Ctrl-` stand-in tab `key` became the daemon's tab `real` (`TabContentCache.adoptStandIn`): the keys typed for it
    /// follow it, so its view still takes them and a close of it still drops them.
    func standInAdopted(_ key: String, as real: String) {
        let old = WindowInputQueue.Target(key), new = WindowInputQueue.Target(real)
        for hold in holds.values {
            hold.creations.rekey(tab: key, to: real)
            hold.queue.retarget(old, to: new)
            if hold.current?.target == old { hold.current?.target = new }
            if hold.shown == old { hold.shown = new }
            if let landing = hold.landsOn.removeValue(forKey: old) { hold.landsOn[new] = landing }
            if let generation = hold.generations.removeValue(forKey: old) { hold.generations[new] = max(generation, hold.generations[new] ?? 0) }
        }
    }

    /// The last key ``capture(_:in:)`` took was dropped (a keyboard claim kept it from the window), not held.
    private(set) var droppedLastKey = false

    /// Whether target `target`'s keys may go now: the focus model names it, its view has the keyboard, and (a creation
    /// still waiting for its reply) its view takes keys before the reply (its early tab, cx-wb5.78). Never another view:
    /// not another terminal, an agent's composer or Home's message box.
    private func takesKeys(_ target: WindowInputQueue.Target, hold: WindowHold, controller: WindowController, window: NSWindow) -> Bool {
        // A key typed into one cmux window never reaches it while another is key (`CmuxApplication.dropsCrossWindowKey`).
        guard NewTabInputCoordinator.mayTakeKey(window, keyWindow: NSApp.keyWindow),
              controller.focus.currentState().resolved.tab == target.id else { return false }
        if let creation = hold.creations.all.first(where: { $0.creation.target == target })?.creation,
           !creation.landed, creation.earlyTab != target.id { return false }
        return Self.responderTakesKeys(controller, window: window)
    }

    /// Runs held key `event` of `window`, typed for `target`, again through the seam (``HeldKeyReplay``, held_by
    /// `creation`), so the hold is a measured stage in `debug.input late_keys` with its own latency slot. While it runs
    /// the window's queue is delivering (``WindowInputQueue/isDelivering``), so no hold captures it again.
    ///
    /// A key that makes another target (a Cmd-D opened a creation, a Ctrl-2 selected a cold tab, a pane focus key moved
    /// the focus) takes the keys typed after it, still waiting for `target`, to that target: the person typed them for it.
    private func runAgain(_ event: NSEvent, for target: WindowInputQueue.Target, hold: WindowHold, in window: NSWindow, router: KeyRouter) {
        let controller = router.focus(for: window).0
        let before = (current: hold.current?.target, generation: controller?.focus.currentState().generation ?? 0)
        replaying = true
        replayedCount += 1
        // The one replay path of held keys (as the New Tab hold's): the key router, then the window's key equivalents and
        // the menu for a chord, then the window that takesKeys found has the target's view as first responder (its own
        // Chromium page window when that is key). Never `NSApplication.sendEvent`, which routes by the key window.
        let to = NSApp.keyWindow.flatMap { $0.parent === window ? $0 : nil } ?? window
        router.heldKeys.replay(event, heldBy: .creation, keyWindow: to) { send in
            router.dispatchingSynthetic(event) {
                guard !router.interceptKeyDown(event, in: window) else { return }
                if KeyRouter.isChord(event.modifierFlags),
                   to.performKeyEquivalent(with: event) || NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return }
                send.window(to, event)
            }
        }
        replaying = false
        guard hold.queue.waiting(for: target) > 0, let state = router.focus(for: window).0?.focus.currentState() else { return }
        if let made = hold.current, made.target != before.current, made.target != target {
            follow(target, to: made.target, generation: made.generation, in: hold)
        } else if state.generation > before.generation, state.resolved.tab != target.id {
            if let tab = state.resolved.tab {
                follow(target, to: WindowInputQueue.Target(tab), generation: state.generation, in: hold)
            } else {
                // The key moved the keyboard out of the content (a sidebar or bar field): the keys after it were typed
                // for no target this queue knows.
                hold.queue.drop(target, .focusMovedAway)
            }
        }
    }

    /// The keys still waiting for `old` are `new`'s from now on (a key that made `new` the target was typed before them,
    /// or `old`'s creation landed on `new`), and so are keys typed next for `old`.
    private func follow(_ old: WindowInputQueue.Target, to new: WindowInputQueue.Target, generation: UInt64, in hold: WindowHold) {
        hold.queue.retarget(old, to: new)
        hold.generations[new] = max(hold.generations[new] ?? 0, generation)
        if hold.current?.target == old { hold.current?.target = new }
    }

    /// The daemon gave back `bytes` typed for terminal `terminalID`, whose creation failed (its error, a closed connection,
    /// no commit within the daemon's expiry: `terminal-input-unclaimed`). They drop, logged in the queue of the window
    /// that showed that terminal (reason targetFailed); they never go to another terminal (principled audit, lagFirstKey
    /// step 4: before, they waited up to 3 s for the window's focused terminal and were typed there).
    func giveBack(_ bytes: Data, terminal terminalID: String) {
        guard let services = router?.services else { return }
        let entry = services.cache.terminals.first { $0.value.io.creatingTerminalID == terminalID }
        let number = entry?.value.session.view.window.map { router?.focus(for: $0).0?.window ?? $0 }?.windowNumber
        let target = WindowInputQueue.Target(entry?.key ?? "terminal:\(terminalID)")
        guard let number, let queue = router?.inputQueues.queue(for: number) else {
            // No window shows it any more: the drop is only logged.
            return WindowInputQueue.logDrop(target, .targetFailed, bytes.count)
        }
        queue.dropGivenBack(bytes.count, for: target)
    }

    /// A focus settle in `window` (every focus-model change ends in one): the held keys are reconciled with it in a new
    /// turn, after the focus queue and outside any action's task.
    func focusDidSettle(in window: NSWindow?) {
        // A claim whose workspace the window shows now ends here, not at a later key (it must not hold again if the
        // window goes back to Home without the person).
        if let window, !claims.isEmpty { _ = activeClaim(in: window) }
        guard let window, holds[window.windowNumber]?.isActive == true else { return }
        scheduleReconcile(in: window)
    }

    private func scheduleReconcile(in window: NSWindow) {
        guard let hold = holds[window.windowNumber], !hold.scheduled else { return }
        hold.scheduled = true
        // task-owner: one reconcile in a fresh main-actor turn, without the creating action's task-locals; a later one
        // reads the same current state, so one pending per window is enough
        Task.detached { @MainActor [weak self, weak window, weak hold] in
            hold?.scheduled = false
            guard let self, let window else { return }
            reconcile(window)
        }
    }

    /// Brings `window`'s held keys in line with its focus model now (level-triggered: it reads only the current state).
    ///
    /// Invariant (principled audit R2, R3, R5): a held key goes only to the target it was typed for, when the model names
    /// that target and its view has the keyboard, in typed order; otherwise it waits, or drops with a reason (its
    /// creation failed or was closed, the person's newer intent left it, the window closed). No timer decides either.
    func reconcile(_ window: NSWindow) {
        guard let hold = holds[window.windowNumber] else { return }
        guard let router, let controller = router.focus(for: window).0 else {
            // The window is gone: its keys go with it (the New Tab hold's too: one queue, one owner).
            windowClosed(window)
            return
        }
        // A reconcile asked for while one runs (a held key's run settled the focus) runs after it, on the state it left.
        guard !hold.reconciling else { return scheduleReconcile(in: window) }
        hold.reconciling = true
        reconcileOnce(hold, controller: controller, window: window, router: router)
        hold.reconciling = false
        syncMode()
    }

    private func reconcileOnce(_ hold: WindowHold, controller: WindowController, window: NSWindow, router: KeyRouter) {
        // 0. Another cmux window is key: the person left this one (its keys could not reach it: `dropsCrossWindowKey`).
        if NSApp.isActive, let key = NSApp.keyWindow, router.focus(for: key).0 != nil,
           !NewTabInputCoordinator.mayTakeKey(window, keyWindow: key) {
            return endWait(hold)
        }
        let state = controller.focus.currentState()
        let named = state.resolved.tab.map(WindowInputQueue.Target.init)
        // 1. Creations the person moved on from (a newer intent replaced the focus each asked for), unless the model names
        // that very target (the person focused it), or the window now shows the new workspace the creation made (showing it
        // is that creation's own landing): their keys drop, they hold nothing more.
        drop(hold.creations.remove { state.generation > $0.generation && $0.target != named && !Self.showsMadeWorkspace($0, state) },
             .focusMovedAway, in: hold)
        // 2. A landed creation's keys follow the tab its focus lands on: the expectation its reply asked for (a daemon
        // surface, the daemon's tab of a stand-in), or, when its tab was not known (a split made at the reply, a new
        // workspace), the tab the model names under the creation's own intent once nothing is pending.
        for (ticket, creation) in hold.creations.all
            where creation.landed && (state.generation == creation.generation || Self.showsMadeWorkspace(creation, state)) {
            if let expectation = state.expectation, expectation.generation == creation.generation {
                hold.landsOn[creation.target] = Self.landingKey(expectation.key)
                continue
            }
            if creation.newWorkspace, state.topology.workspace != creation.workspace { continue }
            let landed = hold.landsOn[creation.target].flatMap { Self.tab(landedOn: $0, in: state.topology) }
            guard let tab = landed ?? (creation.awaitsTab ? named : nil), tab != creation.target else { continue }
            hold.landsOn[creation.target] = nil
            follow(creation.target, to: tab, generation: creation.generation, in: hold)
            hold.creations.setTarget(tab, of: ticket)
        }
        // 3. Keys waiting for a tab no pending creation owns that is gone from the window (closed), or that the person's
        // newer intent left (a cold tab, a target a held key made): they drop, never go elsewhere.
        let pending = Set(hold.creations.all.filter {
            !$0.creation.landed || $0.creation.awaitsTab || state.expectation?.generation == $0.creation.generation
                || hold.landsOn[$0.creation.target] != nil
        }.map { $0.creation.target })
        let owned = Set(hold.creations.all.map { $0.creation.target })
        for target in hold.queue.targets where !target.isNewTabPage && !pending.contains(target) && target != named {
            if !state.topology.panes.contains(where: { $0.tab(target.id) != nil }) {
                hold.queue.drop(target, .targetClosed)
            } else if !owned.contains(target), (hold.generations[target] ?? 0) < state.generation {
                hold.queue.drop(target, .focusMovedAway)
            }
        }
        // 4. The target the model names takes its keys, in order, while its view has the keyboard.
        if let named, hold.queue.waiting(for: named) > 0 {
            hold.queue.drain(named, takesKeys: { takesKeys(named, hold: hold, controller: controller, window: window) }) { event in
                runAgain(event, for: named, hold: hold, in: window, router: router)
            }
        }
        // 5. Creations that hold nothing more: replied, no key waits for them, their focus is not pending, and their
        // target has the keyboard or is not the model's (a tab the person is not on).
        hold.creations.remove { creation in
            guard creation.landed, hold.queue.waiting(for: creation.target) == 0,
                  state.expectation?.generation != creation.generation || state.generation != creation.generation else { return false }
            if creation.newWorkspace, state.topology.workspace != creation.workspace, state.generation == creation.generation { return false }
            return creation.target != named || takesKeys(creation.target, hold: hold, controller: controller, window: window)
        }
        if let shown = hold.shown, hold.queue.waiting(for: shown) == 0,
           shown != named || takesKeys(shown, hold: hold, controller: controller, window: window) {
            hold.shown = nil
        }
        let live = Set(hold.creations.all.map { $0.creation.target }).union(hold.shown.map { [$0] } ?? [])
        if let current = hold.current, !live.contains(current.target), hold.queue.waiting(for: current.target) == 0 { hold.current = nil }
        hold.generations = hold.generations.filter { live.contains($0.key) || hold.queue.waiting(for: $0.key) > 0 }
        hold.landsOn = hold.landsOn.filter { live.contains($0.key) }
    }

    /// The person left every target `hold` waits for (Escape, another cmux window became key): the keys typed for them
    /// drop (focusMovedAway), and the hold waits for nothing more. A creation's later reply still settles the focus.
    private func endWait(_ hold: WindowHold) {
        for target in hold.queue.targets where !target.isNewTabPage { hold.queue.drop(target, .focusMovedAway) }
        drop(hold.creations.remove { _ in true }, .focusMovedAway, in: hold)
        hold.shown = nil
        hold.current = nil
    }

    /// Whether `creation` made a new workspace that the window shows now, its terminal tab not known yet.
    private static func showsMadeWorkspace(_ creation: CreationInputBuffer.Creation, _ state: FocusState) -> Bool {
        creation.newWorkspace && creation.landed && creation.awaitsTab && creation.workspace != nil
            && creation.workspace == state.topology.workspace
    }

    private static func landingKey(_ key: FocusState.Expectation.Key) -> String {
        switch key {
        case .tab(let tab): "tab:\(tab)"
        case .surface(let surface): "surface:\(surface)"
        }
    }

    /// The tab a focus expectation key (`tab:<id>`, `surface:<id>`) names in `topology`, once the window lists it.
    private static func tab(landedOn key: String, in topology: FocusTopology) -> WindowInputQueue.Target? {
        if key.hasPrefix("tab:") {
            let id = String(key.dropFirst(4))
            return topology.panes.contains { $0.tab(id) != nil } ? WindowInputQueue.Target(id) : nil
        }
        let surface = String(key.dropFirst(8))
        for pane in topology.panes {
            if let tab = pane.tabs.first(where: { $0.surface == surface }) { return WindowInputQueue.Target(tab.id) }
        }
        return nil
    }
}

extension CreationInputCoordinator {
    /// False while focus names a terminal whose view does not have the keyboard (another terminal, the window itself
    /// while its view is remounted, or another view: an agent's composer, Home's message box), or names the pane's
    /// selected terminal before its surface is shown: a key now would land in the wrong view or nowhere. Terminal keys
    /// go only to their terminal. Anything else takes the keys.
    static func responderTakesKeys(_ controller: WindowController, window: NSWindow) -> Bool {
        guard case .terminal(let pane, let tab) = controller.focus.state.resolved,
              let paneController = controller.content?.paneController(key: pane) else { return true }
        // Selected, its surface still to come (the pane is empty meanwhile).
        if paneController.currentTabKey != tab { return paneController.stripModel.selectedID?.rawValue != tab }
        guard case .terminal(let entry)? = paneController.currentContent else { return true }
        guard let responder = window.firstResponder as? NSView else { return false }
        return responder === entry.session.surfaceView || responder.isDescendant(of: entry.session.view)
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
