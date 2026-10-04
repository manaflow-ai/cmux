import AppKit
import CmuxNextActions
import CmuxNextBrowser
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
/// 3. the binding table (`RegistryKeyBindings.table`: defaults, then
///    user entries; the last entry whose `when` holds and whose action can
///    run wins), with the context keys of the window the key goes to; else
///    the user's Ghostty keybinds for window, tab and split actions when no
///    terminal has the keyboard;
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
    /// The user's Ghostty host keybinds (`GhosttyRuntime.hostAction`),
    /// injectable for tests.
    var ghosttyHostAction: (NSEvent) -> TerminalHostAction? = { GhosttyRuntime.shared.hostAction(forKeyDown: $0) }
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
        /// A panel or sheet over the window (or no cmux window) has it.
        case panel
    }

    /// Steps 1 and 3-5 for a key-down in a window with `focus` (step 2, the
    /// chord, is stateful and runs in ``interceptKeyDown(_:in:)``).
    func decide(_ event: NSEvent, focus: FocusState, keyWindow: KeyWindowKind, facts: Facts = Facts()) -> Decision {
        guard keyWindow == .content else { return .panel }
        if Self.belongsToInputMethod(event, facts: facts) { return .deliver }
        guard Self.isChord(event.modifierFlags) else {
            let typesHere = facts.primaryInputReady && Self.isPrintable(event) && Self.mayHavePrimaryInput(focus.resolved)
            return typesHere ? .primaryInput : .deliver
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
        // A shortcut recording in a Settings tab takes every key first.
        if let window, services?.windows.owner(of: window) != nil, services?.settingsWindow.handlePaneRecorderKey(event) == true {
            chords.cancel()
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
        guard chords.isPending || isChord else {
            if typesIntoPrimaryInput(event, in: window) { return true }
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
        case .deliver, .panel, .primaryInput:
            return runExtensionShortcut(event, focus: focus)
        }
    }

    /// A printable key on a screen whose primary input should take it
    /// (R65): focus that input and type the key there. Typing in a terminal
    /// never looks up the window (typing-latency path).
    private func typesIntoPrimaryInput(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let window, !(window.firstResponder is TerminalSurfaceView), Self.isPrintable(event) else { return false }
        let (controller, kind) = focus(for: window)
        guard let controller, kind == .content else { return false }
        let focus = controller.focus.state
        guard Self.mayHavePrimaryInput(focus.resolved), let pane = focus.resolved.pane,
              let target = controller.content?.paneController(key: pane)?.currentContent?.primaryInput else { return false }
        let facts = Facts(hasMarkedText: (window.firstResponder as? any NSTextInputClient)?.hasMarkedText() == true,
                          primaryInputReady: target.acceptsRedirectedTyping)
        guard decide(event, focus: focus, keyWindow: kind, facts: facts) == .primaryInput else { return false }
        decided.add(event)
        target.beginTyping(with: event)
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

    // MARK: Resolution

    /// A shortcut a key-down resolves to, before the tier check.
    nonisolated struct Candidate: Equatable, Sendable {
        enum Source: Equatable, Sendable {
            /// A binding table entry (catalog default or cmux.json).
            case registry(argument: String?)
            /// A Ghostty keybind routed to a registry action.
            case ghostty(arguments: [String: ActionValue])
        }

        var id: ActionID
        var tier: ActionKeyTier
        var source: Source
        /// A binding's typed arguments.
        var arguments: [String: ActionValue] = [:]
    }

    /// The winning binding for a key-down in `context`: its characters, then
    /// its unshifted key ("}" or "]" for Shift-]).
    func resolve(_ event: NSEvent, context: KeyContext) -> KeyBinding? {
        let table = RegistryKeyBindings(registry).table
        let bits = context.bits
        for shortcut in ActionRegistry.shortcuts(for: event) {
            if let winner = table.resolve([shortcut], in: context, isRunnable: { [registry] in RegistryKeyBindings(registry).canPerform($0, in: bits) }).winner {
                return winner
            }
        }
        return nil
    }

    /// The candidate for a key-down in a window with `focus` (no chord).
    func candidate(for event: NSEvent, focus: FocusState, facts: Facts = Facts()) -> Candidate? {
        candidate(for: event, context: keyContext(for: focus, facts: facts), focus: focus)
    }

    func candidate(for event: NSEvent, context: KeyContext, focus: FocusState) -> Candidate? {
        if let winner = resolve(event, context: context) {
            return Candidate(id: winner.command, tier: registry.keyTier(for: winner.command), source: .registry(argument: winner.argument),
                             arguments: winner.arguments)
        }
        let isBrowser = BrowserChordTable.isBrowserContext(focus.resolved)
        // Page Back/Forward chords never fall back to a Ghostty keybind.
        if !isBrowser, BrowserChordTable.isBrowserOnlyChord(event, registry: registry) { return nil }
        // Ghostty fallback: never for a browser chord while a page, the
        // address bar or the find bar has the keyboard (Cmd-[ is Back there,
        // not Ghostty's `goto_split:previous`); see BrowserChordTable.
        if isBrowser, BrowserChordTable.isChromeChord(event) { return nil }
        guard let action = ghosttyHostAction(event), let route = TerminalHostActionRoute.route(action) else { return nil }
        return Candidate(id: route.id, tier: registry.keyTier(for: route.id), source: .ghostty(arguments: route.arguments))
    }

    /// A browser-only chord (page Back/Forward) outside a browser context
    /// does nothing and reaches no view (browser focus mode is a browser
    /// context, so it never gets here).
    func consumesBrowserOnlyChord(_ event: NSEvent, focus: FocusState) -> Bool {
        !BrowserChordTable.isBrowserContext(focus.resolved) && BrowserChordTable.isBrowserOnlyChord(event, registry: registry)
    }

    /// Whether the app-wide dispatcher runs `candidate` now: tiers 0 and 1
    /// for a cmux window or a Chromium page window over it (kept for the
    /// tier tables in tests; ``decide(_:focus:keyWindow:facts:)`` is the
    /// whole rule).
    nonisolated static func intercepts(_ candidate: Candidate, focus: FocusState, keyWindow: KeyWindowKind) -> Bool {
        guard keyWindow == .content, candidate.tier != .content else { return false }
        if case .ghostty = candidate.source, case .terminal = focus.resolved { return false }
        return allows(candidate.tier, focus: focus)
    }
}
