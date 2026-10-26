import AppKit
import CmuxNextFocusUI
import CmuxNextCompat
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTerminal
import CmuxNextFocus
/// The one key dispatcher (plans/cmux-next/keybindings.md section 4,
/// focus.md section 5). It decides every key-down of every cmux window in
/// `CmuxApplication.sendEvent` (``interceptKeyDown(_:in:)``), before any
/// window, view or menu sees the key, in this order:
///
/// 0. a Settings shortcut recorder, a popup's close key (a window-kind rule:
///    a close action closes the popup, never the opener's tab), link hints;
/// 1. an input method composing (marked text): the key goes to it;
/// 2. an armed chord (`["ctrl+b", "c"]`, the Cmd-J leader with its which-key
///    overlay): the key completes or cancels it;
/// 3. the binding table (`RegistryKeyBindings.table`: Ghostty fallbacks,
///    defaults, app entries, the user's terminal Ghostty keybinds, then user
///    entries; the last entry whose `when` holds and whose action can run
///    wins), with the context keys of the window the key goes to; a winning
///    Ghostty keybind goes to a focused terminal, which runs it itself;
/// 4. the action's tier decides whether it may take the key from this focus
///    (system always, but in browser focus mode only its exit chord and
///    Quit; navigation unless browser focus mode; content only when its
///    content has the keyboard, never a text field): run it;
/// 5. else the focused surface gets the key (Ghostty keybinds, the page, the
///    field), after a Chrome extension shortcut of the focused Chromium tab;
///    a printable key on a screen with a primary input and no focused text
///    field goes to that input (R65, `PrimaryInputTarget`);
/// 6. main-menu key equivalents are display only for a key decided here:
///    the menu gate refuses them (``allowsMenuKeyEquivalent(_:)``).
///
/// A key the dispatcher never saw (a synthetic event) runs content actions
/// in the window hook (`ShellWindow.performKeyEquivalent`), and the whole
/// dispatcher in Chromium's pre-key hook (`CEFTab.keyRouter`); a decided key
/// runs nothing there, so nothing runs twice.
final class KeyRouter: BrowserKeyRouting {
    unowned let registry: ActionRegistry
    weak var services: AppServices?
    /// A key that is not a Command or Control chord goes on to `window`'s
    /// focused view: the user types into that pane (notification dismissal).
    var onTyping: ((NSWindow?) -> Void)?
    /// The input event being dispatched now (``InputDispatchContext``), `sendEvent`'s and this router's own.
    let inputDispatch: InputDispatchContext
    /// Notes what happens to the key `debug.key` dispatches (nil otherwise).
    var trace: ((String) -> Void)?
    /// The leader's which-key overlay, shown while Cmd-J waits.
    var whichKey: WhichKeyController?
    /// Leaving the app ends a waiting chord (the overlay hides with it); the token removes itself when released.
    private var resignObserver: MainActorObservation?
    init(registry: ActionRegistry, inputDispatch: InputDispatchContext = InputDispatchContext()) {
        self.registry = registry
        self.inputDispatch = inputDispatch
        resignObserver = MainActorObservation(NSApplication.didResignActiveNotification) { [weak self] in self?.cancelChord() }
    }
    // MARK: Tiers
    /// Whether an action of `tier` may take a key from the current focus.
    nonisolated static func allows(_ tier: ActionKeyTier, focus: FocusState) -> Bool {
        switch tier {
        case .system: true
        case .navigation: !focus.isBrowserFocusModeActive
        case .content: !focus.isBrowserFocusModeActive && !focus.resolved.isTextInput && !focus.resolved.isDevTools
        }
    }

    /// Like ``allows(_:focus:)`` for action `id`. The DevTools actions
    /// (Cmd-Opt-I, Cmd-Opt-J, Cmd-Opt-C) are not editing chords: they run
    /// from the page, the address bar, the find bar and DevTools itself.
    /// Browser focus mode still gives them to the page.
    /// Browser focus mode gives the page every system action too (the command palette, Close
    /// Tab), all but ``focusModeKeptActions``.
    nonisolated static func allows(_ tier: ActionKeyTier, id: ActionID, focus: FocusState) -> Bool {
        if focus.isBrowserFocusModeActive, tier == .system { return focusModeKeptActions.contains(id) }
        if tier == .content, devToolsActions.contains(id), BrowserChordTable.isBrowserContext(focus.resolved),
           !focus.isBrowserFocusModeActive { return true }
        if tier == .content, browserChromeActions.contains(id), isBrowserChromeField(focus.resolved) { return true }
        return allows(tier, focus: focus)
    }

    /// The actions DevTools runs itself before its frontend sees the key.
    nonisolated static let devToolsActions: Set<ActionID> = ["toggleBrowserDeveloperTools", "showBrowserJavaScriptConsole",
                                                             "inspectBrowserElement"]

    /// Only chords AppKit treats as key equivalents are candidates, so plain
    /// typing, Option characters and IME input are never intercepted.
    nonisolated static func isChord(_ flags: NSEvent.ModifierFlags) -> Bool {
        !flags.isDisjoint(with: [.command, .control])
    }

    // MARK: Decision

    /// What the dispatcher does with a key-down.
    enum Decision: Equatable {
        /// Run this action and consume the key.
        case run(Candidate)
        /// The focused surface gets the key.
        case deliver
        /// Consume the key and run nothing (a browser-only chord elsewhere).
        case consume
        /// A printable key on a screen with a primary input and no focused
        /// text field: it starts typing in the primary input (R65).
        case primaryInput
        /// A printable key on a page whose document cannot take typing yet:
        /// it waits in the type-ahead queue (app-screens.md section 3).
        case typeAhead
        /// A panel or sheet over the window (or no cmux window) has it.
        case panel
        /// The page gets the key first; this action runs only when the page
        /// reports it did not handle the key (``KeyRouter/runUnhandledPageKey(_:)``).
        case offerToPage(Candidate)
    }

    /// Steps 1 and 3-5 for a key-down in a window with `focus` (step 2, the
    /// chord, is stateful and runs in ``interceptKeyDown(_:in:)``).
    func decide(_ event: NSEvent, focus: FocusState, keyWindow: KeyWindowKind, facts: Facts = Facts()) -> Decision {
        guard keyWindow == .content else { return .panel }
        if Self.belongsToInputMethod(event, facts: facts) { return .deliver }
        guard Self.isChord(event.modifierFlags) else {
            // Printable keys, and the keys the primary input claims (a dead key composes where the key
            // after it goes; Home's history arrows), go to the primary input; only printable keys queue.
            let printable = Self.isPrintable(event)
            guard printable || facts.primaryInputClaimsKey, Self.mayHavePrimaryInput(focus.resolved) else { return .deliver }
            if printable, facts.pageInputPending, Self.mayQueueTyping(focus.resolved) { return .typeAhead }
            return facts.primaryInputReady ? .primaryInput : .deliver
        }
        return decide(event, focus: focus, context: keyContext(for: focus, facts: facts), facts: facts)
    }

    private func decide(_ event: NSEvent, focus: FocusState, context: KeyContext, facts: Facts) -> Decision {
        if editorSequenceTakes(event, focus: focus, context: context, facts: facts) { return .deliver }
        if let candidate = candidate(for: event, context: context, focus: focus) {
            if case .ghostty = candidate.source {
                // A terminal runs its own Ghostty keybinds (in copy mode,
                // which takes keys before Ghostty, the routed action runs);
                // a Ghostty keybind never runs a content action from elsewhere.
                if case .terminal = focus.resolved, !WhenClause.has(KeyContext.terminalCopyMode).evaluate(context) { return .deliver }
                if candidate.tier == .content { return .deliver }
            }
            if Self.allows(candidate.tier, id: candidate.id, focus: focus) {
                return Self.offersToPage(candidate, focus: focus, facts: facts) ? .offerToPage(candidate) : .run(candidate)
            }
        }
        // The code editor's Cmd-[ / Cmd-] are outdent and indent (Monaco), not page Back / Forward.
        guard !context.bits.contains(.codeEditorFocused), consumesBrowserOnlyChord(event, focus: focus) else { return .deliver }
        // On a page with its own history, Cmd-[ / Cmd-] are Go Back / Go Forward (history.md 4.2b).
        if facts.showsPageHistory, let id = BrowserChordTable.pageHistoryAction(for: event, registry: registry) {
            return .run(Candidate(id: id, tier: registry.keyTier(for: id), source: .registry(argument: nil)))
        }
        return .consume
    }

    /// The code editor waits for the second key of its own key sequence (Monaco's Cmd-K Cmd-0,
    /// `cmux.editor.keySequence`): the key is the editor's. Only a system chord (Quit, Hide) runs.
    func editorSequenceTakes(_ event: NSEvent, focus: FocusState, context: KeyContext, facts: Facts) -> Bool {
        guard facts.pageKeySequencePending, context.bits.contains(.codeEditorFocused) else { return false }
        return candidate(for: event, context: context, focus: focus)?.tier != .system
    }

    // MARK: App-wide dispatch

    /// Key-downs this dispatcher decided: the window hook, the Chromium
    /// hook and the menu gate run nothing for them.
    let decided = DecidedKeyEvents()

    /// Step 1: an input method that is composing (marked text) gets every
    /// key it can use, which is every key but a Command chord (Kotoeri's
    /// Ctrl-J/K/L convert); a Command chord (Cmd-W, Cmd-Q) still resolves.
    nonisolated static func belongsToInputMethod(_ event: NSEvent, facts: Facts) -> Bool {
        facts.hasMarkedText && !event.modifierFlags.contains(.command)
    }

    /// Runs from `CmuxApplication.sendEvent` for every key-down of the
    /// process, before any window or responder. `window` is where the key
    /// goes (the key window). Returns whether the key was consumed.
    func interceptKeyDown(_ event: NSEvent, in window: NSWindow?) -> Bool { // perf-hot: 0.5ms key-dispatch (every key-down of the process)
        guard event.type == .keyDown else { return false }
        // A key-down the dispatcher already decided (sent again: a view's doCommand re-sending a chord, a replayed
        // dispatch) is not decided twice: it goes on to AppKit's dispatch, so its action never runs a second time.
        if decided.contains(event) { return false }
        if newTabInputCoordinator.capture(event, in: window) { return true }
        if creationInputCoordinator.capture(event, in: window) { return true }
        // Set again only when this key runs an action (debug.key reports it).
        lastInterception = nil
        if cancelsMissedModal(event, in: window) { return true }
        if runsUndoToast(event, in: window) {
            trace?("undo toast: Cmd-Z ran the toast")
            return true
        }
        // The Keyboard Shortcuts page records keys: its window's keys go to the recorder.
        if let keyRecorder, keyRecorder(event, window) {
            cancelChord()
            trace?("recorder: the Keyboard Shortcuts recorder took the key")
            return true
        }
        if routesPopupKey(event, in: window) {
            cancelChord()
            return true
        }
        // Link hints are showing: their letters, Backspace and Escape.
        if let hints = services?.linkHints, hints.isActive, hints.interceptKeyDown(event, in: window) {
            cancelChord()
            return true
        }
        // Window hints are showing (Click by Hint): the same keys.
        if let hints = services?.windowHints, hints.isActive, hints.interceptKeyDown(event, in: window) {
            cancelChord()
            return true
        }
        // Cmd-P / Cmd-Shift-P (as bound) in a web view outside a main window: the native palette.
        if routesNativePaletteKey(event, in: window) {
            cancelChord()
            return true
        }
        // Browser focus mode: Esc Esc leaves it (the first Escape still reaches the page).
        if routesFocusModeEscape(event, in: window) { return true }
        let isChord = Self.isChord(event.modifierFlags)
        if isChord { dropTypeAhead() }
        guard chords.isPending || isChord else {
            if routesBareKey(event, in: window) { return true }
            if typesAhead(event, in: window) || typesIntoPrimaryInput(event, in: window) { return true }
            onTyping?(window)
            return false
        }
        let (controller, kind) = focus(for: window)
        guard let controller, let window, kind == .content else {
            cancelChord()
            return false
        }
        return dispatch(event, in: window, controller: controller, facts: facts(in: window, controller: controller))
    }

    /// Steps 1-5 for a key-down in `window`, a cmux window or a Chromium
    /// page window over `controller`'s window.
    func dispatch(_ event: NSEvent, in window: NSWindow, controller: WindowController, facts: Facts) -> Bool { // perf-hot: 2ms key-dispatch (every chord)
        // 1. The input method's keys reach it undecided (menus keep their rule).
        if Self.belongsToInputMethod(event, facts: facts) { return false }
        decided.add(event)
        let focus = controller.focus.currentState()
        let context = keyContext(for: focus, facts: facts)
        // The code editor waits for the second key of its own sequence: no app chord arms.
        if editorSequenceTakes(event, focus: focus, context: context, facts: facts) {
            trace?("dispatcher: the code editor's key sequence takes it")
            return false
        }
        // 2. A chord.
        if let consumed = routeChord(event, in: window, controller: controller, context: context, facts: facts) { return consumed }
        guard Self.isChord(event.modifierFlags) else {
            onTyping?(window)
            return false
        }
        // 3-5.
        let decision = decide(event, focus: focus, context: context, facts: facts)
        trace?("dispatcher: \(decision)")
        switch decision {
        case .run(let candidate):
            // The key's own time starts a tab switch's input stage (debug.tab_switch).
            DebugTabSwitch.handling(input: event.timestamp) { run(candidate, context: context, window: controller.state.id) }
            // A refusal (no neighbor) is reported by the registry; the chord
            // was still a cmux shortcut and never reaches the page or terminal.
            return true
        case .consume:
            return true
        case .offerToPage(let candidate):
            // The tab the page key goes to: only its report runs the action (focus can move before Chromium reports).
            guard let tab = focusedBrowserTab(in: controller) else {
                run(candidate, context: context, window: controller.state.id)
                return true
            }
            offerToPage(event, candidate: candidate, context: context, window: controller.state.id, tab: ObjectIdentifier(tab))
            return false
        case .deliver, .panel, .primaryInput, .typeAhead:
            return runExtensionShortcut(event, focus: focus)
        }
    }

    /// A bare key in a page that owns bare keys (KeyRouter+BareKeys): a sequence step, else its binding.
    func dispatchBare(_ event: NSEvent, in window: NSWindow, controller: WindowController, context: KeyContext, facts: Facts) -> Bool {
        if let consumed = routeChord(event, in: window, controller: controller, context: context, facts: facts) { return consumed }
        // `routesBareKey` checked the key is bare and the page owns bare keys.
        guard let winner = resolve(event, context: context) else { return false }
        decided.add(event)
        run(Candidate(id: winner.command, tier: registry.keyTier(for: winner.command), source: .registry(argument: winner.argument),
                      arguments: winner.arguments), context: context, window: controller.state.id)
        return true
    }

    func run(_ candidate: Candidate, context: KeyContext, window: String) {
        lastInterception = (candidate.id, window, true)
        let ran: Bool
        switch candidate.source {
        case .registry(let argument):
            ran = RegistryKeyBindings(registry).run(KeyBinding(keys: [], command: candidate.id, argument: argument, arguments: candidate.arguments),
                                                    keyContext: context.bits)
        case .ghostty(let arguments):
            var invocation = ActionInvocation(arguments: arguments)
            invocation.keyContext = context.bits
            ran = registry.perform(candidate.id, invocation: invocation)
        }
        // A refused run (Cmd-W on a top page) is still a cmux shortcut; debug.key says it did not run.
        lastInterception = (candidate.id, window, ran)
    }

    /// A popup window (or its Chromium page window) has the keyboard: the
    /// binding table decides, with the popup's own context (a browser page,
    /// its omnibar while editing; no main-window focus), and the popup takes
    /// the keys that act on it. A close action (Cmd-W) closes the popup,
    /// never the opener's tab; Focus Location Bar / Focus Address Bar
    /// (Cmd-L) reach the popup's omnibar, never the opener's. Other keys
    /// (Opt-Cmd-F: Search All Windows) go on as before.
    private func routesPopupKey(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let services, let popup = services.popups.window(containing: window), Self.isChord(event.modifierFlags) else { return false }
        var bits = registry.context.subtracting(ActionContext.focusBits).union(.browserFocused)
        if popup.addressBar.isEditing { bits.insert(.omnibarFocused) }
        var context = KeyContext(bits: bits)
        context[KeyContext.windowKind] = .string(KeyContext.WindowKindValue.browserPopup)
        guard let winner = resolve(event, context: context) else { return false }
        if WindowKeyTable.isClose(winner.command) {
            services.popups.close(popup.page)
            return true
        }
        switch winner.command {
        case "focusLocation", "focusBrowserAddressBar":
            popup.focusAddressBar()
            return true
        default:
            return false
        }
    }

    /// Printable keys typed before a page could take them, and the page
    /// (focus, readiness id) they wait for and one delivering now.
    var typeAhead = TypeAheadQueue()
    var typeAheadFocus: FocusState.Resolved?
    var deliveringTypeAhead: String?
    /// The New Tab action owns this buffer before a cold page has a readiness object.
    lazy var newTabInputCoordinator = NewTabInputCoordinator(router: self)
    /// A pending split or terminal tab owns its window's keys until the new terminal has the keyboard (cx-wb5.76).
    lazy var creationInputCoordinator = CreationInputCoordinator(router: self)
    /// Browser focus mode's double-Escape exit (``routesFocusModeEscape(_:in:)``).
    var focusModeEscape = BrowserFocusModeEscapeExit()

    /// Set while the Keyboard Shortcuts page records keys: returns whether
    /// it took the key-down (only its own window's keys).
    var keyRecorder: ((NSEvent, NSWindow?) -> Bool)?
    /// The page whose recorder holds ``keyRecorder`` (one slot for every window's page): only it
    /// clears the slot, and a page that starts recording ends the holder's capture first.
    weak var keyRecorderOwner: AnyObject?
    /// Ends the topmost sheet on a window as cancelled; returns whether one
    /// ended. A seam: tests without a window session (no sheets) replace it.
    var endTopmostSheet: (NSWindow) -> Bool = { SheetDismissal.endTopmost(of: $0) }
    /// The toasts Cmd-Z may undo (`runsUndoToast`); tests replace it.
    var undoToasts: CmuxToastCenter = .shared

    /// The last intercepted action, its window, and whether it ran (false:
    /// refused, such as Cmd-W on a top page) (for `debug.key`).
    private(set) var lastInterception: (action: ActionID, window: String, ran: Bool)? {
        didSet { interceptions += 1 }
    }
    /// Counts `lastInterception` updates, so `debug.key` `last` tells a new key from an old one.
    private(set) var interceptions = 0

    // MARK: Chords

    var chords = ChordTracker()

    /// The key-down a page has first, with the action to run if it reports the key unhandled.
    var pageFirstOffer = PageFirstKeyOffer()

    /// Whether a chord, the Cmd-J leader included, may arm in `focus`:
    /// where content shortcuts run (a terminal, a page, an agent chat, the
    /// sidebar list), never in a text field, DevTools or browser focus mode,
    /// whose own Cmd-J stays theirs, and never while an input method is
    /// composing (marked text), so IME input is never cut short.
    nonisolated static func canArm(focus: FocusState, hasMarkedText: Bool) -> Bool {
        !hasMarkedText && allows(.content, focus: focus)
    }

    /// Ends a waiting chord and hides the leader's overlay (a click, a
    /// window closing, the app resigning active).
    func cancelChord() {
        chords.cancel()
        whichKey?.hide()
    }

    /// `window`'s focus settled: a chord armed there in another focus ends.
    func focusDidSettle(_ focus: FocusState, in window: NSWindow?) {
        typeAheadFocusDidSettle(focus.resolved)
        newTabInputCoordinator.flush(in: window)
        creationInputCoordinator.focusDidSettle(in: window)
        guard chords.isPending, let window, chords.focusDidChange(to: focus.resolved, in: ObjectIdentifier(window)) else { return }
        whichKey?.hide()
    }

    /// A chord key in a cmux window: whether it was consumed, or nil to
    /// route it as usual. Only ``canArm(focus:hasMarkedText:)`` arms a
    /// chord, so the chord's action runs whatever its tier.
    private func routeChord(_ event: NSEvent, in window: NSWindow, controller: WindowController, context: KeyContext,
                            facts: Facts) -> Bool? {
        let focus = controller.focus.state
        let table = RegistryKeyBindings(registry).table
        let bits = context.bits
        let runnable: (ActionID) -> Bool = { [registry] in RegistryKeyBindings(registry).canPerform($0, in: bits) }
        // Keyed by the shell window, as focus settles report it: a Chromium
        // page window is a child of the shell.
        let step = chords.step(event, window: ObjectIdentifier(controller.window ?? window), focus: focus.resolved, table: table,
                               context: context, isRunnable: runnable,
                               canArm: { Self.canArm(focus: focus, hasMarkedText: facts.hasMarkedText) })
        if let keys = chords.armedKeys, let shell = controller.window {
            let rows = WhichKeyListing.rows(after: keys, table: table, context: context, isRunnable: runnable, registry: registry)
            whichKey?.show(after: keys, rows: rows, in: shell)
        } else {
            whichKey?.hide()
        }
        switch step {
        case .pass:
            return nil
        case .armed:
            return true
        case .dismissed:
            // A window or navigation shortcut after the leader runs as itself (Cmd-W closes the tab); a stray key
            // and Escape are consumed, as before.
            return Self.decidesAfterChord(event, resolved: registry.resolveShortcut(for: event)) ? nil : true
        case .run(let id, let argument, let arguments):
            lastInterception = (id, controller.state.id, true)
            let ran = RegistryKeyBindings(registry).run(KeyBinding(keys: [], command: id, argument: argument, arguments: arguments), keyContext: bits)
            lastInterception = (id, controller.state.id, ran)
            return true
        case .mismatch:
            // A window or navigation shortcut after a prefix it does not complete runs as itself: Cmd-W after an
            // armed chord prefix went to the page (or terminal) instead of closing the tab.
            if Self.decidesAfterChord(event, resolved: registry.resolveShortcut(for: event)) { return nil }
            if !Self.isChord(event.modifierFlags) { onTyping?(window) }
            return false
        }
    }

    /// Whether a key that ended an armed chord without completing it is decided as a shortcut of its own (nil from
    /// ``routeChord``): a Command or Control chord bound to a system or navigation action, other than the leader
    /// prefix itself (a second Cmd-J still dismisses the leader). Content shortcuts and typing keep going to the view.
    static func decidesAfterChord(_ event: NSEvent, resolved: (id: ActionID, argument: String?, tier: ActionKeyTier)?) -> Bool {
        guard isChord(event.modifierFlags), let resolved, resolved.tier != .content else { return false }
        return !ActionRegistry.shortcuts(for: event).contains(LeaderLayer.prefix)
    }
}
