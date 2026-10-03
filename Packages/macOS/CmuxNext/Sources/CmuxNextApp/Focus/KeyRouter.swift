import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextTerminal

/// The one keyboard router (plans/cmux-next/focus.md section 5), in two
/// places with one order:
///
/// 0. a chord (`["ctrl+b", "c"]`): its first key, outside text input and
///    browser focus mode, waits for the next key, which runs the chord's
///    action or goes on to the view with no shortcut. The Cmd-J leader
///    (`LeaderLayer`) is such a chord that shows a which-key overlay while
///    it waits and swallows a key that completes nothing;
/// 1. tier 0 (system) actions, always;
/// 2. browser focus mode on the focused page: the page gets the key;
/// 3. tier 1 (navigation) actions, including the user's Ghostty keybinds for
///    window, tab and split actions (`goto_split:left`) when no terminal has
///    the keyboard;
/// 4. a text input has the keyboard: the field and the Edit menu get it;
/// 5. tier 2 (content) actions whose context matches;
/// 6. a Chrome extension shortcut (`chrome.commands`) of the focused
///    Chromium tab's profile, also from the address bar or find bar
///    (Chromium never sees those keys), never in browser focus mode;
/// 7. the focused view (Ghostty keybinds, the page), then the main menu.
///
/// Steps 0-3 run app-wide in `CmuxApplication.sendEvent`
/// (``interceptKeyDown(_:in:)``), before any window or responder sees the
/// key, so they work whichever view or window has it: a terminal, a WebKit
/// page, the address bar, or a Chromium page window (a child window that is
/// key itself). Steps 5 and 6 run per window: `ShellWindow.performKeyEquivalent`
/// for in-window content and Chromium's pre-key hook
/// (``browserTab(_:keyEquivalent:)``) for page windows. Each place runs only
/// its own tiers, so no action runs twice.
final class KeyRouter: BrowserKeyRouting {
    private unowned let registry: ActionRegistry
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
    /// from the page, the address bar, the find bar and
    /// DevTools itself (where other content chords belong to DevTools).
    /// Browser focus mode still gives them to the page.
    nonisolated static func allows(_ tier: ActionKeyTier, id: ActionID, focus: FocusState) -> Bool {
        if tier == .content, devToolsActions.contains(id), BrowserChordTable.isBrowserContext(focus.resolved),
           !focus.isBrowserFocusModeActive { return true }
        return allows(tier, focus: focus)
    }

    /// The actions DevTools runs itself before its frontend sees the key.
    nonisolated static let devToolsActions: Set<ActionID> = ["toggleBrowserDeveloperTools", "showBrowserJavaScriptConsole",
                                                             "inspectBrowserElement"]

    // MARK: App-wide interception (tiers 0 and 1)

    /// A shortcut a key-down resolves to, before the tier check.
    nonisolated struct Candidate: Equatable, Sendable {
        enum Source: Equatable, Sendable {
            /// A registry shortcut (catalog default or `cmux.json`).
            case registry(argument: String?)
            /// A Ghostty keybind routed to a registry action.
            case ghostty(arguments: [String: ActionValue])
        }

        var id: ActionID
        var tier: ActionKeyTier
        var source: Source
    }

    /// Only chords AppKit treats as key equivalents are candidates, so plain
    /// typing, Option characters and IME input are never intercepted.
    nonisolated static func isChord(_ flags: NSEvent.ModifierFlags) -> Bool {
        !flags.isDisjoint(with: [.command, .control])
    }

    /// Whether the app-wide interceptor runs `candidate` now: tiers 0 and 1
    /// for a cmux window or a Chromium page window over it, by the focus of
    /// that window. Panels and sheets over a window (palette, rename, group
    /// editor, confirmations) keep their keys; the main menu, gated by
    /// ``allowsMenu(_:focus:keyWindow:)``, still sees what they pass on.
    /// Tier 2 is never intercepted: the window or page hook runs it after
    /// the text-input check.
    nonisolated static func intercepts(_ candidate: Candidate, focus: FocusState, keyWindow: KeyWindowKind) -> Bool {
        guard keyWindow == .content, candidate.tier != .content else { return false }
        if case .ghostty = candidate.source, case .terminal = focus.resolved {
            // The terminal runs its own Ghostty keybinds (same action).
            return false
        }
        return allows(candidate.tier, focus: focus)
    }

    /// Runs from `CmuxApplication.sendEvent` for every key-down of the
    /// process, before any window or responder. `window` is where the key
    /// goes (the key window). Returns whether the key was consumed.
    func interceptKeyDown(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard event.type == .keyDown else { return false }
        // A popup panel (or its Chromium page window) has the keyboard:
        // Cmd-W closes the popup, never the opener's tab.
        if services?.popups.interceptKeyDown(event, in: window) == true {
            cancelChord()
            return true
        }
        // Link hints are showing: their letters, Backspace and Escape.
        if let hints = services?.linkHints, hints.isActive, hints.interceptKeyDown(event, in: window) {
            cancelChord()
            return true
        }
        // Plain typing never looks up the window (typing-latency path).
        if chords.isPending || Self.isChord(event.modifierFlags), let consumed = routeChord(event, in: window) { return consumed }
        guard Self.isChord(event.modifierFlags) else {
            onTyping?(window)
            return false
        }
        let (controller, kind) = focus(for: window)
        guard let controller, kind == .content else { return false }
        guard let candidate = candidate(for: event, focus: controller.focus.state),
              Self.intercepts(candidate, focus: controller.focus.state, keyWindow: kind) else {
            return consumesBrowserOnlyChord(event, focus: controller.focus.state)
        }
        lastInterception = (candidate.id, controller.state.id)
        switch candidate.source {
        case .registry(let argument):
            registry.runShortcut(candidate.id, argument: argument)
        case .ghostty(let arguments):
            registry.perform(candidate.id, invocation: ActionInvocation(arguments: arguments))
        }
        // A refusal (no neighbor) is reported by the registry; the chord was
        // still a cmux shortcut and never reaches the page or the terminal.
        return true
    }

    // MARK: Chords (two-key shortcuts)

    private var chords = ChordTracker()
    /// The key after a chord's first key that completed none: it goes on to
    /// the focused view, but runs no shortcut there or in the menu.
    private weak var chordMismatch: NSEvent?

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
    private func routeChord(_ event: NSEvent, in window: NSWindow?) -> Bool? {
        let (controller, kind) = focus(for: window)
        guard let controller, let window, kind == .content else {
            cancelChord()
            return nil
        }
        let step = chords.step(event, window: ObjectIdentifier(window), registry: registry, focus: controller.focus.state.resolved) {
            Self.canArm(focus: controller.focus.state,
                        hasMarkedText: (window.firstResponder as? any NSTextInputClient)?.hasMarkedText() == true)
        }
        if let leader = chords.leaderPrefix, let shell = controller.window {
            whichKey?.show(after: leader, in: shell)
        } else {
            whichKey?.hide()
        }
        switch step {
        case .pass:
            return nil
        case .armed, .dismissed:
            return true
        case .run(let id, let argument):
            lastInterception = (id, controller.state.id)
            registry.runShortcut(id, argument: argument)
            return true
        case .mismatch:
            chordMismatch = event
            if !Self.isChord(event.modifierFlags) { onTyping?(window) }
            return false
        }
    }

    /// A browser-only chord (page Back/Forward) outside a browser context
    /// does nothing and reaches no view (browser focus mode is a browser
    /// context, so it never gets here).
    func consumesBrowserOnlyChord(_ event: NSEvent, focus: FocusState) -> Bool {
        !BrowserChordTable.isBrowserContext(focus.resolved) && BrowserChordTable.isBrowserOnlyChord(event, registry: registry)
    }

    /// The last intercepted action and window (for `debug.key`).
    private(set) var lastInterception: (action: ActionID, window: String)?

    func candidate(for event: NSEvent, focus: FocusState) -> Candidate? {
        if let resolved = registry.resolveShortcut(for: event) {
            return Candidate(id: resolved.id, tier: resolved.tier, source: .registry(argument: resolved.argument))
        }
        let isBrowser = BrowserChordTable.isBrowserContext(focus.resolved)
        // Page Back/Forward chords never fall back to a Ghostty keybind.
        if !isBrowser, BrowserChordTable.isBrowserOnlyChord(event, registry: registry) { return nil }
        // Browser tab-switching chords (Ctrl-Tab, Ctrl-PageDown...) are
        // cmux's next/previous tab in a browser context. Unbinding the
        // action in cmux.json removes these aliases too.
        if isBrowser, let id = BrowserChordTable.tabNavigationAction(for: event), registry.effectiveShortcut(for: id) != nil {
            return Candidate(id: id, tier: registry.keyTier(for: id), source: .registry(argument: nil))
        }
        // Ghostty fallback: never for a browser chord while a page,
        // the address bar or the find bar has the keyboard (Cmd-[ is Back
        // there, not Ghostty's `goto_split:previous`); see BrowserChordTable.
        if isBrowser, BrowserChordTable.isChromeChord(event) { return nil }
        guard let action = ghosttyHostAction(event), let route = TerminalHostActionRoute.route(action) else { return nil }
        return Candidate(id: route.id, tier: registry.keyTier(for: route.id), source: .ghostty(arguments: route.arguments))
    }

    // MARK: Per-window content shortcuts (tier 2)

    /// Runs the tier 2 action `event` resolves to when the focus allows it
    /// (not in a text field, not in browser focus mode). Tiers 0 and 1 ran
    /// app-wide already. Returns whether the key was consumed.
    func routeContentKeyEquivalent(_ event: NSEvent, focus: FocusState) -> Bool {
        if event === chordMismatch { return false }
        if let resolved = registry.resolveShortcut(for: event), resolved.tier == .content,
           !isPageKey(event, id: resolved.id), Self.allows(.content, id: resolved.id, focus: focus) {
            return registry.runShortcut(resolved.id, argument: resolved.argument)
        }
        return runExtensionShortcut(event, focus: focus)
    }

    /// Chromium dispatches extension shortcuts from the Chromium toolbar that
    /// cmux hides, and never sees keys while the omnibar or find bar has the
    /// keyboard, so cmux routes them for the focused Chromium tab.
    private func runExtensionShortcut(_ event: NSEvent, focus: FocusState) -> Bool {
        guard !focus.isBrowserFocusModeActive, let pane = focus.resolved.pane,
              let paneController = services?.windows.controllers.lazy.compactMap({ $0.content?.paneController(key: pane) }).first,
              case .browser(let entry)? = paneController.currentContent,
              let tab = entry.tab as? CEFTab,
              let command = tab.extensionStore.command(matching: event) else { return false }
        return tab.extensionStore.run(command, in: tab)
    }

    // MARK: Menu key equivalents

    /// Where the key window stands relative to a cmux window.
    nonisolated enum KeyWindowKind: Equatable, Sendable {
        /// The cmux window itself, or a Chromium page window over it.
        case content
        /// A panel or sheet over it (palette, rename sheet): its text field
        /// has the keyboard.
        case textPanel
        /// Not ours (no focus to consult).
        case other
    }

    /// Installed as `ActionRegistry.menuKeyEquivalentGate`: a main-menu key
    /// equivalent may run `id` only when its tier may take the key from the
    /// key window's focus, so browser focus mode and text fields keep
    /// chords the router gave them (focus.md section 5).
    func allowsMenuKeyEquivalent(_ id: ActionID) -> Bool {
        if let event = NSApp.currentEvent, event === chordMismatch { return false }
        let (controller, kind) = keyWindowFocus()
        guard let controller else { return true }
        return Self.allowsMenu(registry.keyTier(for: id), id: id, focus: controller.focus.state, keyWindow: kind)
    }

    nonisolated static func allowsMenu(_ tier: ActionKeyTier, id: ActionID? = nil, focus: FocusState, keyWindow: KeyWindowKind) -> Bool {
        switch keyWindow {
        case .other: true
        case .textPanel: tier != .content
        case .content: id.map { allows(tier, id: $0, focus: focus) } ?? allows(tier, focus: focus)
        }
    }

    private func keyWindowFocus() -> (WindowController?, KeyWindowKind) {
        guard let services else { return (nil, .other) }
        // No key window (the app is inactive, or an automation launch):
        // menu actions target the active window, so its focus decides.
        guard let key = NSApp.keyWindow else { return (services.windows.active, .content) }
        return focus(for: key)
    }

    /// The cmux window `window` belongs to and how.
    func focus(for window: NSWindow?) -> (WindowController?, KeyWindowKind) {
        guard let services, let window else { return (nil, .other) }
        let controllers = services.windows.controllers
        if let controller = controllers.first(where: { $0.window === window }) { return (controller, .content) }
        let owner = window.parent ?? window.sheetParent
        // A Chromium page window in a popup panel: the panel's window gates
        // menu chords like a panel (content chords stay with the page).
        if let panel = owner as? NSPanel, let grand = panel.parent,
           let controller = controllers.first(where: { $0.window === grand }) { return (controller, .textPanel) }
        guard let controller = controllers.first(where: { $0.window === owner }) else { return (nil, .other) }
        return (controller, window is NSPanel || window.sheetParent != nil ? .textPanel : .content)
    }

    // MARK: BrowserKeyRouting (CEF page window is key)

    /// A letter the page did not handle outside any text field (Chromium
    /// reports it after the page): runs the content action bound to that
    /// single key, such as link hints (`f`, `F`), when that page has the
    /// keyboard. Plain keys never reach ``interceptKeyDown(_:in:)``, so
    /// typing in a terminal or a text field never gets here.
    func routePageKey(_ key: BrowserPageKey, from tab: any BrowserTab) {
        guard let services, !services.linkHints.isActive, let controller = window(showing: tab),
              case .browserPage(_, let shown) = controller.focus.state.resolved, shown == services.cache.key(of: tab),
              Self.allows(.content, focus: controller.focus.state),
              let resolved = registry.resolve(Shortcut(key.character, modifiers: key.shift ? [.shift] : [])),
              registry.descriptor(for: resolved.id)?.requires.contains(.browserFocused) == true else { return }
        registry.runShortcut(resolved.id, argument: resolved.argument)
    }

    /// A key without Command, Control or Option bound to a browser action
    /// (link hints): it runs only from ``routePageKey(_:from:)``, after the
    /// page passed it on, never before a page (WebKit's included) whose
    /// text field may want the letter.
    func isPageKey(_ event: NSEvent, id: ActionID) -> Bool {
        event.modifierFlags.isDisjoint(with: [.command, .control, .option])
            && registry.descriptor(for: id)?.requires.contains(.browserFocused) == true
    }

    func pageOwnsAllKeys(_ tab: any BrowserTab) -> Bool {
        window(showing: tab)?.focus.state.isBrowserFocusModeActive ?? false
    }

    /// Chromium's pre-key hook: tier 2 and extension shortcuts (tiers 0 and
    /// 1 ran in `sendEvent` before Chromium saw the key).
    func browserTab(_ tab: any BrowserTab, keyEquivalent event: NSEvent) -> BrowserKeyDisposition {
        guard let controller = window(showing: tab) else { return .passToPage }
        return routeContentKeyEquivalent(event, focus: controller.focus.state) ? .handledByHost : .passToPage
    }

    /// Before a docked or undocked DevTools sees a key: only the DevTools
    /// actions (Cmd-Opt-I closes it, Cmd-Opt-J, Cmd-Opt-C).
    /// Tiers 0 and 1 ran app-wide already; content chords (Copy, Reload)
    /// belong to the DevTools frontend.
    func browserTab(_ tab: any BrowserTab, devToolsKeyEquivalent event: NSEvent) -> BrowserKeyDisposition {
        guard let resolved = registry.resolveShortcut(for: event), Self.devToolsActions.contains(resolved.id),
              let devTools = tab as? any BrowserDevToolsHosting else { return .passToPage }
        switch resolved.id.rawValue {
        case "toggleBrowserDeveloperTools": devTools.performDevTools(.toggle)
        case "showBrowserJavaScriptConsole": devTools.performDevTools(.console)
        default: devTools.performDevTools(.inspectElement)
        }
        return .handledByHost
    }

    private func window(showing tab: any BrowserTab) -> WindowController? {
        services?.windows.controllers.first { controller in
            controller.content?.panes.values.contains { pane in
                if case .browser(let entry)? = pane.currentContent { return entry.tab === tab }
                return false
            } ?? false
        }
    }
}
