import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextFocus
import CmuxNextInput

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
        if decided.contains(event) || Self.overlayHasKeys(focus) { return false }
        let context = keyContext(for: focus, facts: Facts())
        // A Ghostty keybind never runs a content action from a hook (the terminal runs its own).
        if let winner = resolve(event, context: context), !winner.source.isGhostty, registry.keyTier(for: winner.command) == .content,
           !isPageKey(event, id: winner.command), Self.allows(.content, id: winner.command, focus: focus) {
            return RegistryKeyBindings(registry).run(winner, keyContext: context.bits)
        }
        return runExtensionShortcut(event, focus: focus)
    }

    /// The view a chord the dispatcher decided goes to as a key equivalent, instead of AppKit's
    /// depth-first walk over every view of the window. Chrome's `CommandDispatcher` gives a key to a
    /// first responder that is a `CommandDispatcherTarget` the same way, with no walk
    /// (ui/base/cocoa/command_dispatcher.mm, `performKeyEquivalent:`).
    /// - A surface that takes its own key equivalents (a terminal, a page host): that view alone. Every
    ///   other view that takes a chord in a pane (a find bar, a dialog, a Mac Screen button) takes it
    ///   only while it holds the keyboard.
    /// - A field editor in a pane: that pane, whose walk reaches the field's own ancestors (a find bar's
    ///   Cmd-G, the browser chrome's keys), never a sibling pane.
    ///
    /// Nil for any other key or responder (a field outside every pane): AppKit's walk.
    func directKeyEquivalentTarget(for event: NSEvent, firstResponder: NSResponder?) -> NSView? { // perf-hot: 0.5ms key-dispatch (every chord a window gets)
        guard Self.isChord(event.modifierFlags), let view = firstResponder as? NSView, decided.contains(event) else { return nil }
        if Self.takesOwnKeyEquivalents(view) {
            decided.offers.focusedSurface += 1
            trace?("window: key equivalent to the focused surface only")
            return view
        }
        if (view as? NSTextView)?.isFieldEditor == true, let pane = Self.enclosingPane(of: view) {
            decided.offers.fieldPane += 1
            trace?("window: key equivalent to the field's pane only")
            return pane
        }
        decided.offers.windowWalks += 1
        return nil
    }

    /// The pane that holds `view`, nil outside every pane.
    static func enclosingPane(of view: NSView) -> PaneContentView? {
        var ancestor = view.superview
        while let current = ancestor {
            if let pane = current as? PaneContentView { return pane }
            ancestor = current.superview
        }
        return nil
    }

    /// A surface whose key equivalents are its own while it is first responder: the terminal (its
    /// Ghostty keybinds), a Chromium host page and, in Debug and bench builds, the remote browser page
    /// (their page's keys). Each adopts ``KeyEquivalentOwningSurface`` in its own module, so a Release
    /// build compiles this with no Debug-only type.
    static func takesOwnKeyEquivalents(_ view: NSView) -> Bool {
        view is any KeyEquivalentOwningSurface
    }

    /// An overlay (palette, sheet, rename, group editor) has the keyboard. AppKit also offers
    /// the main window behind it a key equivalent its panel did not handle; that key is the
    /// overlay's, so nothing below takes it (cx-6so.46: Cmd-K in the palette cleared the
    /// terminal, whose context bits the palette keeps).
    nonisolated static func overlayHasKeys(_ focus: FocusState) -> Bool {
        !focus.overlays.isEmpty
    }

    /// Chromium dispatches extension shortcuts from the Chromium toolbar that
    /// cmux hides, and never sees keys while the omnibar or find bar has the
    /// keyboard, so cmux routes them for the focused Chromium tab.
    /// Chromium's pre-key hook looks up the profile's shortcuts only for a key this did not settle
    /// (``extensionShortcutsLookedUp``): browser focus mode, or a pane's Chromium tab whose shortcuts it read.
    func runExtensionShortcut(_ event: NSEvent, focus: FocusState) -> Bool {
        if focus.isBrowserFocusModeActive {
            extensionShortcutsLookedUp.add(event)
            return false
        }
        guard let pane = focus.resolved.pane,
              let paneController = services?.windows.controllers.lazy.compactMap({ $0.content?.paneController(key: pane) }).first,
              case .browser(let entry)? = paneController.currentContent,
              let tab = entry.tab as? CEFTab else { return false }
        extensionShortcutsLookedUp.add(event)
        guard let command = tab.extensionStore.command(matching: event) else { return false }
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
    /// Runs `body` while `event` is dispatched outside `NSApplication.sendEvent` (`debug.key`, a
    /// replayed held key): the same dispatch context `sendEvent` uses (``InputDispatchContext``).
    func dispatchingSynthetic<T>(_ event: NSEvent, _ body: () -> T) -> T {
        inputDispatch.dispatching(event, body)
    }

    /// Whether a terminal may offer `event` to the main menu before Ghostty
    /// (`TerminalKeyEquivalent.menuMayClaim`).
    func menuMayClaim(_ event: NSEvent) -> Bool {
        !decided.contains(event)
    }

    func allowsMenuKeyEquivalent(_ id: ActionID) -> Bool {
        let allowed = menuGate(id)
        trace?("menu gate \(id.rawValue): \(allowed ? "allowed" : "refused")")
        return allowed
    }

    private func menuGate(_ id: ActionID) -> Bool {
        if let event = inputDispatch.event, event.type == .keyDown, decided.contains(event),
           !Self.menuKeyEquivalentAllowedAfterDispatch(registry.keyTier(for: id), eventWasDecided: true) { return false }
        // A page's keyboard lock takes cmux's chords from the main menu too, not only from the dispatcher
        // (``keyboardLockTakes(_:facts:)``): the key went to the page, so no menu item runs it after.
        if !Self.keyboardLockKeeps.contains(id), keyWindowPageLocksKeys?() ?? pageLocksKeysInKeyWindow() { return false }
        let (controller, kind) = keyWindowFocus()
        guard let controller else { return true }
        return Self.allowsMenu(registry.keyTier(for: id), id: id, focus: controller.focus.state, keyWindow: kind)
    }

    /// Menu equivalents are a fallback for keys that reached a content view.
    /// The dispatcher marks every key it examines so content actions cannot
    /// run twice; system actions need an explicit policy here because the
    /// terminal may still be the next responder for the same event.
    nonisolated static func menuKeyEquivalentAllowedAfterDispatch(_ tier: ActionKeyTier,
                                                                   eventWasDecided: Bool) -> Bool {
        !eventWasDecided || tier == .system
    }

    nonisolated static func allowsMenu(_ tier: ActionKeyTier, id: ActionID? = nil, focus: FocusState, keyWindow: KeyWindowKind) -> Bool {
        switch keyWindow {
        case .other: true
        case .textPanel: tier != .content
        case .content: id.map { allows(tier, id: $0, focus: focus) } ?? allows(tier, focus: focus)
        }
    }

    /// ``KeyFacts/pageLocksKeys`` of the key window's live facts; false outside a cmux content window.
    private func pageLocksKeysInKeyWindow() -> Bool {
        guard let key = NSApp.keyWindow else { return false }
        let (controller, kind) = focus(for: key)
        guard let controller, kind == .content else { return false }
        return facts(in: key, controller: controller).pageLocksKeys
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
        if let controller = controllers.first(where: { $0.window === window }) {
            // An overlay of the window's top layer has the keyboard: it gates keys as its panel did.
            return (controller, (window as? ShellWindow)?.overlayHasKeyboard == true ? .textPanel : .content)
        }
        // A popup window (or the Chromium page window in it) gates menu
        // chords like a panel over the window that opened it.
        if let popup = services.popups.window(containing: window) {
            let opener = services.popups.openerWindow(of: popup)
            return (controllers.first { $0.window === opener }, .textPanel)
        }
        let owner = window.parent ?? window.sheetParent
        // A Chromium page window in a panel: the panel's window gates
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
        guard let winner = RegistryKeyBindings(registry).table.resolveWinner(CollectionOfOne(shortcut), in: context, isRunnable: { [registry] in
            RegistryKeyBindings(registry).canPerform($0, in: bits)
        }), registry.descriptor(for: winner.command)?.requires.contains(.browserFocused) == true else { return }
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

    /// Chromium's report that the page left a key-down unhandled: runs the cmux action the
    /// dispatcher held for it (``runUnhandledPageKey(_:)``), such as Find after a page that has
    /// no search of its own.
    func browserTab(_ tab: any BrowserTab, unhandledKeyEquivalent event: NSEvent) -> Bool {
        runUnhandledPageKey(event, from: ObjectIdentifier(tab))
    }

    func pageOwnsAllKeys(_ tab: any BrowserTab) -> Bool {
        window(showing: tab)?.focus.state.isBrowserFocusModeActive ?? false
    }

    /// Asked first by Chromium's pre-key hook (`CEFRuntime.routeKey`): a decided key, or Chromium's copy of it, never runs
    /// the dispatcher again, and only one whose extension shortcuts the dispatcher did not look up still looks them up.
    func decidedKey(_ event: NSEvent) -> BrowserDecidedKey { // perf-hot: 0.5ms key-dispatch (every chord a Chromium page gets)
        guard decided.contains(event) else { return .undecided }
        return extensionShortcutsLookedUp.contains(event) ? .settled : .extensionShortcutOwed
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
        browserPaneWindow(showing: tab)
            // A cmux page in Chromium (ChromiumPageHost) is no pane's browser entry: its view's window.
            ?? services?.windows.controllers.first { $0.window != nil && $0.window === tab.contentView.window }
    }

    private func browserPaneWindow(showing tab: any BrowserTab) -> WindowController? {
        services?.windows.controllers.first { controller in
            controller.content?.panes.values.contains { pane in
                if case .browser(let entry)? = pane.currentContent { return entry.tab === tab }
                return false
            } ?? false
        }
    }
}
