import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTerminal

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
///    (system always; navigation unless browser focus mode; content only
///    when its content has the keyboard, never a text field): run it;
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
    /// The key-down `debug.key` dispatches (``dispatchingSynthetic(_:_:)``),
    /// which `NSApp.currentEvent` does not report.
    var syntheticKeyEvent: NSEvent?
    /// The leader's which-key overlay, shown while Cmd-J waits.
    var whichKey: WhichKeyController?
    private var resignObserver: (any NSObjectProtocol)?

    init(registry: ActionRegistry) {
        self.registry = registry
        // Leaving the app ends a waiting chord (the overlay hides with it).
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelChord() }
        }
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
    nonisolated static func allows(_ tier: ActionKeyTier, id: ActionID, focus: FocusState) -> Bool {
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
    }

    /// Steps 1 and 3-5 for a key-down in a window with `focus` (step 2, the
    /// chord, is stateful and runs in ``interceptKeyDown(_:in:)``).
    func decide(_ event: NSEvent, focus: FocusState, keyWindow: KeyWindowKind, facts: Facts = Facts()) -> Decision {
        guard keyWindow == .content else { return .panel }
        if Self.belongsToInputMethod(event, facts: facts) { return .deliver }
        guard Self.isChord(event.modifierFlags) else {
            guard Self.isPrintable(event), Self.mayHavePrimaryInput(focus.resolved) else { return .deliver }
            if facts.pageInputPending, Self.mayQueueTyping(focus.resolved) { return .typeAhead }
            return facts.primaryInputReady ? .primaryInput : .deliver
        }
        return decide(event, focus: focus, context: keyContext(for: focus, facts: facts))
    }

    private func decide(_ event: NSEvent, focus: FocusState, context: KeyContext) -> Decision {
        if let candidate = candidate(for: event, context: context, focus: focus) {
            if case .ghostty = candidate.source {
                // A terminal runs its own Ghostty keybinds; a Ghostty
                // keybind never runs a content action from elsewhere.
                if case .terminal = focus.resolved { return .deliver }
                if candidate.tier == .content { return .deliver }
            }
            if Self.allows(candidate.tier, id: candidate.id, focus: focus) { return .run(candidate) }
        }
        return consumesBrowserOnlyChord(event, focus: focus) ? .consume : .deliver
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
    func interceptKeyDown(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard event.type == .keyDown else { return false }
        if cancelsMissedModal(event, in: window) { return true }
        if runsUndoToast(event, in: window) { return true }
        // The Keyboard Shortcuts page records keys: its window's keys go to the recorder.
        if let keyRecorder, keyRecorder(event, window) {
            cancelChord()
            return true
        }
        if closesPopup(event, in: window) {
            cancelChord()
            return true
        }
        // Link hints are showing: their letters, Backspace and Escape.
        if let hints = services?.linkHints, hints.isActive, hints.interceptKeyDown(event, in: window) {
            cancelChord()
            return true
        }
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
    func dispatch(_ event: NSEvent, in window: NSWindow, controller: WindowController, facts: Facts) -> Bool {
        // 1. The input method's keys reach it undecided (menus keep their rule).
        if Self.belongsToInputMethod(event, facts: facts) { return false }
        decided.add(event)
        let focus = controller.focus.state
        let context = keyContext(for: focus, facts: facts)
        // 2. A chord.
        if let consumed = routeChord(event, in: window, controller: controller, context: context, facts: facts) { return consumed }
        guard Self.isChord(event.modifierFlags) else {
            onTyping?(window)
            return false
        }
        // 3-5.
        switch decide(event, focus: focus, context: context) {
        case .run(let candidate):
            run(candidate, context: context, window: controller.state.id)
            // A refusal (no neighbor) is reported by the registry; the chord
            // was still a cmux shortcut and never reaches the page or terminal.
            return true
        case .consume:
            return true
        case .deliver, .panel, .primaryInput, .typeAhead:
            return runExtensionShortcut(event, focus: focus)
        }
    }

    /// A bare key in a page that owns bare keys (KeyRouter+BareKeys): a sequence step, else its binding.
    func dispatchBare(_ event: NSEvent, in window: NSWindow, controller: WindowController, context: KeyContext, facts: Facts) -> Bool {
        if let consumed = routeChord(event, in: window, controller: controller, context: context, facts: facts) { return consumed }
        guard let winner = bareKeyWinner(event, context: context) else { return false }
        decided.add(event)
        run(Candidate(id: winner.command, tier: registry.keyTier(for: winner.command), source: .registry(argument: winner.argument),
                      arguments: winner.arguments), context: context, window: controller.state.id)
        return true
    }

    private func run(_ candidate: Candidate, context: KeyContext, window: String) {
        lastInterception = (candidate.id, window)
        switch candidate.source {
        case .registry(let argument):
            RegistryKeyBindings(registry).run(KeyBinding(keys: [], command: candidate.id, argument: argument, arguments: candidate.arguments),
                                keyContext: context.bits)
        case .ghostty(let arguments):
            var invocation = ActionInvocation(arguments: arguments)
            invocation.keyContext = context.bits
            registry.perform(candidate.id, invocation: invocation)
        }
    }

    /// A popup panel (or its Chromium page window) has the keyboard: a key
    /// whose binding is a close action (Cmd-W) closes the popup, never the
    /// opener's tab. The binding table decides which key that is, with the
    /// popup's own context (no main-window focus).
    private func closesPopup(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let services, let panel = services.popups.panel(containing: window), Self.isChord(event.modifierFlags) else { return false }
        var context = KeyContext(bits: registry.context.subtracting(ActionContext.focusBits))
        context[KeyContext.windowKind] = .string(KeyContext.WindowKindValue.browserPopup)
        guard let winner = resolve(event, context: context) else { return false }
        guard WindowKeyTable.isClose(winner.command) else { return false }
        services.popups.close(panel.page)
        return true
    }

    /// Printable keys typed before a page could take them, and the page
    /// (focus, readiness id) they wait for and one delivering now.
    var typeAhead = TypeAheadQueue()
    var typeAheadFocus: FocusState.Resolved?
    var deliveringTypeAhead: String?

    /// Set while the Keyboard Shortcuts page records keys: returns whether
    /// it took the key-down (only its own window's keys).
    var keyRecorder: ((NSEvent, NSWindow?) -> Bool)?
    /// Ends the topmost sheet on a window as cancelled; returns whether one
    /// ended. A seam: tests without a window session (no sheets) replace it.
    var endTopmostSheet: (NSWindow) -> Bool = { SheetDismissal.endTopmost(of: $0) }
    /// The toasts Cmd-Z may undo (`runsUndoToast`); tests replace it.
    var undoToasts: CmuxToastCenter = .shared

    /// The last intercepted action and window (for `debug.key`).
    private(set) var lastInterception: (action: ActionID, window: String)?

    // MARK: Chords

    var chords = ChordTracker()

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
        case .armed, .dismissed:
            return true
        case .run(let id, let argument, let arguments):
            lastInterception = (id, controller.state.id)
            RegistryKeyBindings(registry).run(KeyBinding(keys: [], command: id, argument: argument, arguments: arguments), keyContext: bits)
            return true
        case .mismatch:
            if !Self.isChord(event.modifierFlags) { onTyping?(window) }
            return false
        }
    }
}
