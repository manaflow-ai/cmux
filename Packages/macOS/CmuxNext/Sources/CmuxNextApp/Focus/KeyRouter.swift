import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextTerminal

/// The one keyboard router (plans/cmux-next/focus.md section 5), in two
/// places with one order:
///
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
/// Steps 1-3 run app-wide in `CmuxApplication.sendEvent`
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
    /// The user's Ghostty host keybinds (`GhosttyRuntime.hostAction`),
    /// injectable for tests.
    var ghosttyHostAction: (NSEvent) -> TerminalHostAction? = { GhosttyRuntime.shared.hostAction(forKeyDown: $0) }

    init(registry: ActionRegistry) {
        self.registry = registry
    }

    /// Whether an action of `tier` may take a key from the current focus.
    nonisolated static func allows(_ tier: ActionKeyTier, focus: FocusState) -> Bool {
        switch tier {
        case .system: true
        case .navigation: !focus.isBrowserFocusModeActive
        case .content: !focus.isBrowserFocusModeActive && !focus.resolved.isTextInput && !focus.resolved.isDevTools
        }
    }

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
        guard event.type == .keyDown, Self.isChord(event.modifierFlags) else { return false }
        let (controller, kind) = focus(for: window)
        guard let controller, kind == .content, let candidate = candidate(for: event, focus: controller.focus.state),
              Self.intercepts(candidate, focus: controller.focus.state, keyWindow: kind) else { return false }
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

    /// The last intercepted action and window (for `debug.key`).
    private(set) var lastInterception: (action: ActionID, window: String)?

    func candidate(for event: NSEvent, focus: FocusState) -> Candidate? {
        if let resolved = registry.resolveShortcut(for: event) {
            return Candidate(id: resolved.id, tier: resolved.tier, source: .registry(argument: resolved.argument))
        }
        let isBrowser = BrowserChordTable.isBrowserContext(focus.resolved)
        // Chrome's tab-switching chords (Ctrl-Tab, Ctrl-PageDown...) are
        // cmux's next/previous tab in a browser context. Unbinding the
        // action in cmux.json removes these aliases too.
        if isBrowser, let id = BrowserChordTable.tabNavigationAction(for: event), registry.effectiveShortcut(for: id) != nil {
            return Candidate(id: id, tier: registry.keyTier(for: id), source: .registry(argument: nil))
        }
        // Ghostty fallback: never for a chord Chrome defines while a page,
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
        if let resolved = registry.resolveShortcut(for: event), resolved.tier == .content,
           Self.allows(.content, focus: focus) {
            return registry.runShortcut(resolved.id, argument: resolved.argument)
        }
        return runExtensionShortcut(event, focus: focus)
    }

    /// Chromium dispatches extension shortcuts from the Chrome toolbar that
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
        let (controller, kind) = keyWindowFocus()
        guard let controller else { return true }
        return Self.allowsMenu(registry.keyTier(for: id), focus: controller.focus.state, keyWindow: kind)
    }

    nonisolated static func allowsMenu(_ tier: ActionKeyTier, focus: FocusState, keyWindow: KeyWindowKind) -> Bool {
        switch keyWindow {
        case .other: true
        case .textPanel: tier != .content
        case .content: allows(tier, focus: focus)
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
        guard let controller = controllers.first(where: { $0.window === owner }) else { return (nil, .other) }
        return (controller, window is NSPanel || window.sheetParent != nil ? .textPanel : .content)
    }

    // MARK: BrowserKeyRouting (CEF page window is key)

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
    /// actions (Cmd-Opt-I closes it, Cmd-Opt-J, Cmd-Opt-C), as in Chrome.
    /// Tiers 0 and 1 ran app-wide already; content chords (Copy, Reload)
    /// belong to the DevTools frontend.
    func browserTab(_ tab: any BrowserTab, devToolsKeyEquivalent event: NSEvent) -> BrowserKeyDisposition {
        guard let resolved = registry.resolveShortcut(for: event), WebInspector.devToolsActions.contains(resolved.id.rawValue),
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
