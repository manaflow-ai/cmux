import AppKit
import CmuxNextActions
import CmuxNextBrowser

// The places a key can reach after the dispatcher: the window hook, the
// Chromium hooks and main-menu key equivalents. Each runs nothing for a key
// the dispatcher decided (`decided`), so no action runs twice.
extension KeyRouter {
    // MARK: Window hook (a key the dispatcher never saw)

    /// Runs the content action `event` resolves to when the focus allows it
    /// (not in a text field, not in browser focus mode), then a Chrome
    /// extension shortcut. Only for a key the dispatcher never saw (a
    /// synthetic event): the dispatcher already decided every real key-down.
    func routeContentKeyEquivalent(_ event: NSEvent, focus: FocusState) -> Bool {
        if decided.contains(event) { return false }
        let context = keyContext(for: focus, facts: Facts())
        // A Ghostty keybind never runs a content action from a hook (the terminal runs its own).
        if let winner = resolve(event, context: context), !winner.source.isGhostty, registry.keyTier(for: winner.command) == .content,
           !isPageKey(event, id: winner.command), Self.allows(.content, id: winner.command, focus: focus) {
            return RegistryKeyBindings(registry).run(winner, keyContext: context.bits)
        }
        return runExtensionShortcut(event, focus: focus)
    }

    /// Chromium dispatches extension shortcuts from the Chromium toolbar that
    /// cmux hides, and never sees keys while the omnibar or find bar has the
    /// keyboard, so cmux routes them for the focused Chromium tab.
    func runExtensionShortcut(_ event: NSEvent, focus: FocusState) -> Bool {
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

    /// Installed as `ActionRegistry.menuKeyEquivalentGate`. A key-down the
    /// dispatcher decided never runs a menu item (menus are display only
    /// for keys). Other key windows (panels, sheets, windows of their own)
    /// follow the tier rule of the key window's focus.
    /// Runs `body` while `event` is dispatched outside
    /// `NSApplication.sendEvent` (`debug.key`), where `NSApp.currentEvent`
    /// is not that event.
    func dispatchingSynthetic<T>(_ event: NSEvent, _ body: () -> T) -> T {
        let previous = syntheticKeyEvent
        syntheticKeyEvent = event
        defer { syntheticKeyEvent = previous }
        return body()
    }

    /// Whether a terminal may offer `event` to the main menu before Ghostty
    /// (`TerminalKeyEquivalent.menuMayClaim`).
    func menuMayClaim(_ event: NSEvent) -> Bool {
        true
    }

    func allowsMenuKeyEquivalent(_ id: ActionID) -> Bool {
        let allowed = menuGate(id)
        trace?("menu gate \(id.rawValue): \(allowed ? "allowed" : "refused")")
        return allowed
    }

    private func menuGate(_ id: ActionID) -> Bool {
        if let event = syntheticKeyEvent ?? NSApp.currentEvent, event.type == .keyDown, decided.contains(event) { return false }
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
    /// keyboard. Plain keys never reach the dispatcher, so typing in a
    /// terminal or a text field never gets here.
    func routePageKey(_ key: BrowserPageKey, from tab: any BrowserTab) {
        guard let services, !services.linkHints.isActive, let controller = window(showing: tab),
              case .browserPage(_, let shown) = controller.focus.state.resolved, shown == services.cache.key(of: tab),
              Self.allows(.content, focus: controller.focus.state) else { return }
        let context = keyContext(for: controller.focus.state, facts: Facts())
        let bits = context.bits
        let shortcut = Shortcut(key.character, modifiers: key.shift ? [.shift] : [])
        guard let winner = RegistryKeyBindings(registry).table.resolve([shortcut], in: context, isRunnable: { [registry] in
            RegistryKeyBindings(registry).canPerform($0, in: bits)
        }).winner, registry.descriptor(for: winner.command)?.requires.contains(.browserFocused) == true else { return }
        RegistryKeyBindings(registry).run(winner, keyContext: bits)
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

    /// Chromium's pre-key hook (`CEFTab.keyRouter`): a key the dispatcher
    /// decided in `sendEvent` goes to the page; a key that reached Chromium
    /// without passing `sendEvent` runs the whole dispatcher here, in the
    /// same order (chord, binding table, tier, extension shortcut).
    func browserTab(_ tab: any BrowserTab, keyEquivalent event: NSEvent) -> BrowserKeyDisposition {
        guard !decided.contains(event), let controller = window(showing: tab), let window = controller.window else { return .passToPage }
        return dispatch(event, in: window, controller: controller, facts: Facts()) ? .handledByHost : .passToPage
    }

    /// Before a docked or undocked DevTools sees a key: only the DevTools
    /// actions (Cmd-Opt-I closes it, Cmd-Opt-J, Cmd-Opt-C). Content chords
    /// (Copy, Reload) belong to the DevTools frontend.
    func browserTab(_ tab: any BrowserTab, devToolsKeyEquivalent event: NSEvent) -> BrowserKeyDisposition {
        guard !decided.contains(event), let resolved = registry.resolveShortcut(for: event), Self.devToolsActions.contains(resolved.id),
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
