import AppKit
import CmuxSettings
import WebKit

struct ShortcutEventFocusContext {
    let browserPanel: BrowserPanel?
    let markdownPanel: MarkdownPanel?
    let rightSidebarFocused: Bool
    /// The full context snapshot a ``ShortcutWhenClause`` evaluates against: the
    /// focus atoms plus the non-focus keys (`commandPaletteVisible`, `sidebarMode`,
    /// `terminalFindVisible`, `paneCount`, `workspaceCount`) read from the shortcut
    /// window's state.
    let shortcutContext: ShortcutContext

    /// Projects the runtime focus snapshot onto the atoms a
    /// ``ShortcutWhenClause`` evaluates against.
    var focusState: ShortcutFocusState {
        ShortcutFocusState(
            browser: browserPanel != nil,
            markdown: markdownPanel != nil,
            sidebar: rightSidebarFocused
        )
    }
}

struct ShortcutEventFocusContextCache {
    let event: NSEvent
    let context: ShortcutEventFocusContext
}

extension KeyboardShortcutSettings.Action {
    enum ShortcutContext: Equatable {
        case application
        case nonBrowserPanel
        case browserPanel
        case markdownPanel
        case rightSidebarFocus

        var isAlwaysAvailable: Bool {
            self == .application
        }

        func isAvailable(focusedBrowserPanel: Bool, focusedMarkdownPanel: Bool, rightSidebarFocused: Bool) -> Bool {
            switch self {
            case .application:
                return true
            case .nonBrowserPanel:
                return !focusedBrowserPanel && !rightSidebarFocused
            case .browserPanel:
                return focusedBrowserPanel
            case .markdownPanel:
                return focusedMarkdownPanel
            case .rightSidebarFocus:
                return rightSidebarFocused
            }
        }

        func isAvailable(_ context: ShortcutEventFocusContext) -> Bool {
            isAvailable(
                focusedBrowserPanel: context.browserPanel != nil,
                focusedMarkdownPanel: context.markdownPanel != nil,
                rightSidebarFocused: context.rightSidebarFocused
            )
        }

        /// The built-in context expressed as a ``ShortcutWhenClause``, used as the
        /// default when an action has no `shortcuts.when` override in cmux.json.
        var defaultWhenClause: ShortcutWhenClause {
            switch self {
            case .application:
                return .always
            case .nonBrowserPanel:
                return .and(.not(.atom(.browserFocus)), .not(.atom(.sidebarFocus)))
            case .browserPanel:
                return .atom(.browserFocus)
            case .markdownPanel:
                return .atom(.markdownFocus)
            case .rightSidebarFocus:
                return .atom(.sidebarFocus)
            }
        }

        func overlaps(_ other: ShortcutContext) -> Bool {
            if self == .application || other == .application {
                return true
            }
            if self == other {
                return true
            }
            // A focused markdown viewer also satisfies `.nonBrowserPanel`, so the
            // two contexts can be active at the same time. Treat them as
            // overlapping so shortcut conflict detection rejects a chord bound to
            // both a markdown-zoom action and a non-browser action.
            if (self == .markdownPanel && other == .nonBrowserPanel) ||
                (self == .nonBrowserPanel && other == .markdownPanel) {
                return true
            }
            return false
        }
    }

    /// Whether `handleCustomShortcut` consumes this action before general
    /// configured-shortcut matching whenever its context holds (the
    /// `rightSidebarModeShortcut` pre-route). Priority-resolved pairs — the
    /// sidebar's `⌃1…5` over the Select Surface `⌃1…9` family — coexist in
    /// conflict detection because the winner owns the overlapping context and
    /// the other binding keeps every other state. Mirrors
    /// `ShortcutAction.hasPriorityShortcutRouting` in CmuxSettings; the drift
    /// test asserts the two stay aligned.
    var hasPriorityShortcutRouting: Bool {
        switch self {
        case .switchRightSidebarToFiles, .switchRightSidebarToFind,
             .switchRightSidebarToSessions, .switchRightSidebarToFeed, .switchRightSidebarToDock:
            return true
        default:
            return false
        }
    }

    var shortcutContext: ShortcutContext {
        switch self {
        case .diffViewerScrollDown,
             .diffViewerScrollUp,
             .diffViewerScrollToBottom,
             .diffViewerScrollToTop,
             .diffViewerOpenFileSearch:
            return .browserPanel
        case .switchRightSidebarToFiles, .switchRightSidebarToFind, .switchRightSidebarToSessions, .switchRightSidebarToFeed, .switchRightSidebarToDock:
            return .rightSidebarFocus
        case .renameTab, .renameWorkspace, .sendCtrlFToTerminal, .clearScreenKeepScrollback:
            return .nonBrowserPanel
        case .browserBack, .browserForward, .browserReload, .browserHardReload, .toggleBrowserDeveloperTools, .showBrowserJavaScriptConsole,
             .browserZoomIn, .browserZoomOut, .browserZoomReset, .toggleBrowserFocusMode:
            return .browserPanel
        case .markdownZoomIn, .markdownZoomOut, .markdownZoomReset:
            return .markdownPanel
        default:
            return .application
        }
    }

    /// Whether this action is also surfaced as an `NSMenuItem` key equivalent.
    ///
    /// The stale-menu-shortcut suppressor (``AppDelegate/shouldSuppressStaleCmuxMenuShortcut(event:)``)
    /// only needs to suppress a remapped-away *default* binding for actions that
    /// have a menu item still carrying the old key equivalent; the three
    /// non-menu actions below are routed purely in code, so their default
    /// binding can never reach the menu and never needs suppression.
    var isMenuBacked: Bool {
        self != .showHideAllWindows && self != .globalSearch && self != .clearScreenKeepScrollback
    }

    /// Whether this action closes a tab, workspace, or window.
    ///
    /// The stale-shortcut suppressor treats close actions specially: a stale
    /// default ⌘W must be suppressed even when no current binding matches, so a
    /// menu close item does not fire on a key the user has rebound away.
    var isCloseAction: Bool {
        switch self {
        case .closeTab, .closeWorkspace, .closeWindow:
            return true
        default:
            return false
        }
    }
}

extension Notification.Name {
    static let debugBrowserReloadShortcutInvoked = Notification.Name("cmux.debugBrowserReloadShortcutInvoked")
    static let debugBrowserHardReloadShortcutInvoked = Notification.Name("cmux.debugBrowserHardReloadShortcutInvoked")
}

extension AppDelegate {
    func reloadBrowserPanelForShortcut(_ panel: BrowserPanel) {
#if DEBUG
        NotificationCenter.default.post(name: .debugBrowserReloadShortcutInvoked, object: panel)
#endif
        panel.reload()
    }

    func hardReloadBrowserPanelForShortcut(_ panel: BrowserPanel) {
#if DEBUG
        NotificationCenter.default.post(name: .debugBrowserHardReloadShortcutInvoked, object: panel)
#endif
        panel.hardReload()
    }

    func shortcutEventBrowserPanel(_ event: NSEvent) -> BrowserPanel? {
        shortcutEventFocusContext(event).browserPanel
    }

    func shortcutEventMarkdownPanel(_ event: NSEvent) -> MarkdownPanel? {
        shortcutEventFocusContext(event).markdownPanel
    }

    func shortcutEventFocusContext(_ event: NSEvent) -> ShortcutEventFocusContext {
        if let cache = shortcutEventFocusContextCache, cache.event === event {
            return cache.context
        }

        let shortcutWindow = shortcutResolvedEventWindow(event) ?? NSApp.keyWindow ?? NSApp.mainWindow
        let browserPanel = shortcutEventFocusedBrowserPanel(event) ?? shortcutWebInspectorFocusedBrowserPanel(in: shortcutWindow)
        // Only treat a markdown panel as focused when no browser panel owns the
        // event, so a focused browser never routes markdown shortcuts.
        let markdownPanel = browserPanel == nil ? shortcutFocusedMarkdownPanel(in: shortcutWindow) : nil
        let rightSidebarFocused = shortcutWindow.map { shouldRouteRightSidebarModeShortcut(in: $0) } ?? false
        let focusState = ShortcutFocusState(
            browser: browserPanel != nil,
            markdown: markdownPanel != nil,
            sidebar: rightSidebarFocused
        )
        let context = ShortcutEventFocusContext(
            browserPanel: browserPanel,
            markdownPanel: markdownPanel,
            rightSidebarFocused: rightSidebarFocused,
            shortcutContext: buildShortcutContext(focusState: focusState, window: shortcutWindow)
        )
        shortcutEventFocusContextCache = ShortcutEventFocusContextCache(event: event, context: context)
        return context
    }

    /// Builds the full ``ShortcutContext`` for a shortcut event: the focus atoms
    /// (via ``ShortcutFocusState/context``) plus the non-focus context keys read
    /// synchronously from the shortcut window's state. Called once per event (the
    /// result is cached in ``shortcutEventFocusContextCache``).
    private func buildShortcutContext(focusState: ShortcutFocusState, window: NSWindow?) -> ShortcutContext {
        var context = focusState.context
        context.setBool(
            ShortcutContextKnownKey.commandPaletteVisible.rawValue,
            window.map { isCommandPaletteVisible(for: $0) } ?? false
        )
        if let tabManager = shortcutContextTabManager(in: window) {
            context.setInt(ShortcutContextKnownKey.workspaceCount.rawValue, tabManager.tabs.count)
            if let workspace = tabManager.selectedWorkspace {
                context.setInt(ShortcutContextKnownKey.paneCount.rawValue, workspace.panels.count)
                context.setBool(
                    ShortcutContextKnownKey.terminalFindVisible.rawValue,
                    workspace.focusedTerminalPanel?.searchState != nil
                )
            }
        }
        if let mode = window.flatMap({ keyboardFocusCoordinator(for: $0)?.activeRightSidebarMode }) {
            context.setString(ShortcutContextKnownKey.sidebarMode.rawValue, mode.rawValue)
        }
        return context
    }

    /// The ``TabManager`` driving the shortcut window, falling back to the app's
    /// current tab manager when the window is unknown.
    private func shortcutContextTabManager(in window: NSWindow?) -> TabManager? {
        if let window,
           let context = registeredMainWindow(forWindow: window) {
            return context.tabManager
        }
        return tabManager
    }

    private func shortcutFocusedMarkdownPanel(in window: NSWindow?) -> MarkdownPanel? {
        // `focusedMarkdownPanel` is already gated to preview mode, where the
        // rendered viewer responds to zoom (the raw text editor does not).
        if let window {
            guard let context = registeredMainWindow(forWindow: window) else {
                return nil
            }
            return context.tabManager.focusedMarkdownPanel
        }

        return tabManager?.focusedMarkdownPanel
    }

    func clearShortcutEventFocusContextCache(for event: NSEvent) {
        if shortcutEventFocusContextCache?.event === event {
            shortcutEventFocusContextCache = nil
        }
    }

    func shortcutEventFocusedBrowserPanel(_ event: NSEvent) -> BrowserPanel? {
        guard let shortcutWindow = shortcutResolvedEventWindow(event) ?? NSApp.keyWindow ?? NSApp.mainWindow else {
            return nil
        }

        let responder = shortcutWindow.firstResponder
        if cmuxOwningGhosttyView(for: responder) != nil {
            return nil
        }

        if let panelId = focusedBrowserAddressBarPanelIdForShortcutEvent(event),
           let panel = shortcutBrowserPanel(panelId: panelId) {
            return panel
        }

        if let responder,
           let panelId = BrowserWindowPortalRegistry.searchOverlayPanelId(for: responder, in: shortcutWindow),
           let panel = shortcutBrowserPanel(panelId: panelId) {
            return panel
        }

        if let webView = shortcutOwningWebView(for: responder) {
            return shortcutBrowserPanel(webView: webView)
        }

        if let panel = shortcutFocusedBrowserPanel(in: shortcutWindow) {
            return panel
        }

        return nil
    }

    private func shortcutFocusedBrowserPanel(in window: NSWindow?) -> BrowserPanel? {
        if let window {
            guard let context = registeredMainWindow(forWindow: window) else {
                return nil
            }
            return context.tabManager.focusedBrowserPanel
        }

        return tabManager?.focusedBrowserPanel
    }

    private func shortcutWebInspectorFocusedBrowserPanel(in window: NSWindow?) -> BrowserPanel? {
        let responder = window?.firstResponder ?? NSApp.keyWindow?.firstResponder ?? NSApp.mainWindow?.firstResponder
        guard cmuxIsLikelyWebInspectorResponder(responder) else { return nil }

        if let window,
           let context = registeredMainWindow(forWindow: window) {
            return shortcutFocusedBrowserPanel(in: context.window ?? window)
        }

        return shortcutFocusedBrowserPanel(in: window)
    }

    private func shortcutResolvedEventWindow(_ event: NSEvent) -> NSWindow? {
        if let window = event.window {
            return window
        }
        guard event.windowNumber > 0 else { return nil }
        return NSApp.window(withWindowNumber: event.windowNumber)
    }

    private func shortcutBrowserPanel(panelId: UUID) -> BrowserPanel? {
        for manager in shortcutCandidateTabManagers() {
            for workspace in manager.tabs {
                if let panel = workspace.browserPanel(for: panelId) {
                    return panel
                }
            }
        }
        return nil
    }

    private func shortcutBrowserPanel(webView: WKWebView) -> BrowserPanel? {
        for manager in shortcutCandidateTabManagers() {
            for workspace in manager.tabs {
                for panel in workspace.panels.values {
                    guard let browserPanel = panel as? BrowserPanel,
                          browserPanel.webView === webView else {
                        continue
                    }
                    return browserPanel
                }
            }
        }
        return nil
    }

    private func shortcutCandidateTabManagers() -> [TabManager] {
        let candidates = [tabManager] + registeredMainWindows.map { Optional($0.tabManager) }
        var seen = Set<ObjectIdentifier>()
        var managers: [TabManager] = []
        for candidate in candidates {
            guard let candidate else { continue }
            let id = ObjectIdentifier(candidate)
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            managers.append(candidate)
        }
        return managers
    }

    private func shortcutOwningWebView(for responder: NSResponder?) -> WKWebView? {
        guard let responder else { return nil }
        if let webView = responder as? WKWebView {
            return webView
        }

        if let textView = responder as? NSTextView,
           textView.isFieldEditor,
           let ownerView = cmuxFieldEditorOwnerView(textView),
           let webView = shortcutOwningWebView(for: ownerView) {
            return webView
        }

        if let view = responder as? NSView,
           let webView = shortcutOwningWebView(for: view) {
            return webView
        }

        var current = responder.nextResponder
        while let next = current {
            if let webView = next as? WKWebView {
                return webView
            }
            if let view = next as? NSView,
               let webView = shortcutOwningWebView(for: view) {
                return webView
            }
            current = next.nextResponder
        }

        return nil
    }

    private func shortcutOwningWebView(for view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView {
            return webView
        }

        var current: NSView? = view.superview
        while let candidate = current {
            if let webView = candidate as? WKWebView {
                return webView
            }
            if String(describing: type(of: candidate)).contains("WindowBrowserSlotView"),
               let portalWebView = shortcutUniqueBrowserWebView(in: candidate) {
                if view === portalWebView || view.isDescendant(of: portalWebView) {
                    return portalWebView
                }
                if shortcutAllowsPortalSlotTextEntryFocus(view) {
                    return nil
                }
                return portalWebView
            }
            current = candidate.superview
        }

        return nil
    }

    private func shortcutAllowsPortalSlotTextEntryFocus(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if let textField = candidate as? NSTextField {
                return textField.isEditable || textField.acceptsFirstResponder
            }
            if let textView = candidate as? NSTextView {
                return textView.isEditable || textView.isSelectable || textView.isFieldEditor
            }
            current = candidate.superview
        }
        return false
    }

    private func shortcutUniqueBrowserWebView(in root: NSView) -> WKWebView? {
        var stack: [NSView] = [root]
        var found: WKWebView?
        while let current = stack.popLast() {
            if let webView = current as? WKWebView {
                if found == nil {
                    found = webView
                } else if found !== webView {
                    return nil
                }
            }
            stack.append(contentsOf: current.subviews)
        }
        return found
    }
}
