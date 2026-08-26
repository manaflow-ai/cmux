import AppKit
import CmuxSettings
import CmuxSimulatorUI
import WebKit

struct ShortcutEventFocusContext {
    let browserPanel: BrowserPanel?
    let markdownPanel: MarkdownPanel?
    let filePreviewTextEditorFocused: Bool
    let simulatorFocused: Bool
    let simulatorPanel: SimulatorPanel?
    let simulatorTextEditorFocused: Bool
    let rightSidebarFocused: Bool
    /// The full context snapshot a ``ShortcutWhenClause`` evaluates against.
    let shortcutContext: ShortcutContext

    init(
        browserPanel: BrowserPanel?,
        markdownPanel: MarkdownPanel?,
        filePreviewTextEditorFocused: Bool,
        simulatorFocused: Bool,
        simulatorPanel: SimulatorPanel? = nil,
        simulatorTextEditorFocused: Bool = false,
        rightSidebarFocused: Bool,
        shortcutContext: ShortcutContext
    ) {
        self.browserPanel = browserPanel
        self.markdownPanel = markdownPanel
        self.filePreviewTextEditorFocused = filePreviewTextEditorFocused
        self.simulatorFocused = simulatorFocused
        self.simulatorPanel = simulatorPanel
        self.simulatorTextEditorFocused = simulatorTextEditorFocused
        self.rightSidebarFocused = rightSidebarFocused
        self.shortcutContext = shortcutContext
    }

    var allowsSimulatorShortcutRouting: Bool {
        simulatorFocused && !simulatorTextEditorFocused
    }

    /// Projects the runtime focus snapshot onto the atoms a
    /// ``ShortcutWhenClause`` evaluates against.
    var focusState: ShortcutFocusState {
        ShortcutFocusState(
            browser: browserPanel != nil,
            markdown: markdownPanel != nil,
            sidebar: rightSidebarFocused,
            filePreviewTextEditor: filePreviewTextEditorFocused,
            simulator: simulatorFocused
        )
    }
}

func shortcutResponderAcceptsTextEditing(_ responder: NSResponder) -> Bool {
    if let textView = responder as? NSTextView {
        return textView.isEditable || textView.isSelectable || textView.isFieldEditor
    }
    if let textField = responder as? NSTextField {
        return textField.isEditable || textField.isSelectable
    }
    return false
}

struct ShortcutEventFocusContextCache {
    let event: NSEvent
    let context: ShortcutEventFocusContext
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
        let simulatorPanel = shortcutFocusedSimulatorPanel(in: shortcutWindow)
        let simulatorFocused = simulatorPanel != nil
        let simulatorTextEditorFocused = simulatorFocused
            && shortcutWindow?.firstResponder.map(shortcutResponderAcceptsTextEditing) == true
        let browserPanel = simulatorFocused
            ? nil
            : shortcutEventFocusedBrowserPanel(event) ?? shortcutWebInspectorFocusedBrowserPanel(in: shortcutWindow)
        // Only treat a markdown panel as focused when no browser panel owns the
        // event, so a focused browser never routes markdown shortcuts.
        let markdownPanel = browserPanel == nil ? shortcutFocusedMarkdownPanel(in: shortcutWindow) : nil
        let filePreviewTextEditorFocused = browserPanel == nil && markdownPanel == nil
            ? shortcutFocusedFilePreviewTextEditor(in: shortcutWindow)
            : false
        let rightSidebarFocused = !simulatorFocused
            && (shortcutWindow.map { shouldRouteRightSidebarModeShortcut(in: $0) } ?? false)
        let focusState = ShortcutFocusState(
            browser: browserPanel != nil,
            markdown: markdownPanel != nil,
            sidebar: rightSidebarFocused,
            filePreviewTextEditor: filePreviewTextEditorFocused,
            simulator: simulatorFocused
        )
        let context = ShortcutEventFocusContext(
            browserPanel: browserPanel,
            markdownPanel: markdownPanel,
            filePreviewTextEditorFocused: filePreviewTextEditorFocused,
            simulatorFocused: simulatorFocused,
            simulatorPanel: simulatorPanel,
            simulatorTextEditorFocused: simulatorTextEditorFocused,
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
            window.map { isCommandPaletteEffectivelyVisible(for: $0) } ?? false
        )
        if let tabManager = shortcutContextTabManager(in: window) {
            context.setInt(ShortcutContextKnownKey.workspaceCount.rawValue, tabManager.tabs.count)
            if let workspace = tabManager.selectedWorkspace {
                context.setInt(ShortcutContextKnownKey.paneCount.rawValue, workspace.panels.count)
                context.setBool(ShortcutContextKnownKey.workspaceCanvasLayout.rawValue, workspace.layoutMode == .canvas)
                context.setBool(
                    ShortcutContextKnownKey.terminalFindVisible.rawValue,
                    workspace.focusedTerminalInputTarget()?.panel.searchState != nil
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
        if let context = shortcutMainWindowContext(in: window) {
            return context.tabManager
        }
        return tabManager
    }

    private func shortcutMainWindowContext(in window: NSWindow?) -> MainWindowContext? {
        guard let window else { return nil }
        return mainWindowContexts[ObjectIdentifier(window)] ??
            mainWindowContexts.values.first(where: { $0.window === window })
    }

    private func shortcutFocusedMarkdownPanel(in window: NSWindow?) -> MarkdownPanel? {
        // `focusedMarkdownPanel` is already gated to preview mode, where the
        // rendered viewer responds to zoom (the raw text editor does not).
        if let window {
            guard let context = shortcutMainWindowContext(in: window) else {
                return nil
            }
            return context.tabManager.focusedMarkdownPanel
        }

        return tabManager?.focusedMarkdownPanel
    }

    private func shortcutFocusedFilePreviewTextEditor(in window: NSWindow?) -> Bool {
        guard let focusedFilePreviewPanel = shortcutContextTabManager(in: window)?.focusedTextFilePreviewPanel,
              let textView = shortcutFocusedSavingTextView(in: window),
              let owningFilePreviewPanel = textView.panel as? FilePreviewPanel,
              owningFilePreviewPanel === focusedFilePreviewPanel else {
            return false
        }

        return true
    }

    private func shortcutFocusedSavingTextView(in window: NSWindow?) -> SavingTextView? {
        guard let responder = window?.firstResponder ?? NSApp.keyWindow?.firstResponder ?? NSApp.mainWindow?.firstResponder else {
            return nil
        }
        if let textView = responder as? SavingTextView {
            return textView
        }

        var current = responder.nextResponder
        while let next = current {
            if let textView = next as? SavingTextView {
                return textView
            }
            current = next.nextResponder
        }
        return nil
    }

    @discardableResult
    func handleFocusedFileExplorerOpenSelectionShortcut(_ event: NSEvent, preferredWindow: NSWindow? = nil) -> Bool {
        let window = preferredWindow ?? shortcutResolvedEventWindow(event) ?? NSApp.keyWindow ?? NSApp.mainWindow
        guard let window,
              let responder = window.firstResponder,
              let focusView = shortcutFileExplorerFocusView(for: responder),
              focusView.window === window || focusView.window?.windowNumber == window.windowNumber else {
            return false
        }

        if let outlineView = focusView as? FileExplorerNSOutlineView {
            return outlineView.handleOpenSelectionShortcut(event)
        }
        if let resultsView = focusView as? FileExplorerSearchResultsTableView {
            return resultsView.handleOpenSelectionShortcut(event)
        }
        if let searchField = focusView as? FileExplorerSearchField {
            return searchField.handleOpenSelectionShortcut(event)
        }
        return false
    }

    private func shortcutFileExplorerFocusView(for responder: NSResponder) -> NSView? {
        if let textView = responder as? NSTextView,
           textView.isFieldEditor,
           let ownerView = cmuxFieldEditorOwnerView(textView) {
            return fileExplorerShortcutFocusRoot(containing: ownerView)
        }

        if let view = responder as? NSView {
            return fileExplorerShortcutFocusRoot(containing: view)
        }

        return nil
    }

    private func fileExplorerShortcutFocusRoot(containing view: NSView) -> NSView? {
        var current: NSView? = view
        while let candidate = current {
            if isFileExplorerShortcutFocusRoot(candidate) {
                return candidate
            }
            current = candidate.superview
        }
        return nil
    }

    private func isFileExplorerShortcutFocusRoot(_ view: NSView) -> Bool {
        view is FileExplorerNSOutlineView ||
            view is FileExplorerSearchResultsTableView ||
            view is FileExplorerSearchField
    }

    func clearShortcutEventFocusContextCache(for event: NSEvent) {
        if shortcutEventFocusContextCache?.event === event {
            shortcutEventFocusContextCache = nil
        }
    }

    /// Drops the bounded browser ownership cache after an event has completed.
    /// Chord handling intentionally does not call this helper mid-dispatch,
    /// because the same NSEvent can cross several AppKit routing boundaries.
    func clearShortcutEventBrowserWebViewCache(for event: NSEvent) {
        event.cmuxBrowserWebViewCache = nil
    }

    func shortcutEventFocusedBrowserPanel(_ event: NSEvent) -> BrowserPanel? {
        guard let shortcutWindow = shortcutResolvedEventWindow(event) ?? NSApp.keyWindow ?? NSApp.mainWindow else {
            return nil
        }

        let responder = shortcutWindow.firstResponder
        if let dockBrowser = shortcutActiveWindowDockBrowserPanel(
            in: shortcutWindow
        ) {
            return dockBrowser
        }
        if responder.cmuxStrictOwningGhosttyView() != nil {
            return nil
        }

        if let panelId = focusedBrowserAddressBarPanelIdForShortcutEvent(event),
           let panel = shortcutBrowserPanel(panelId: panelId, in: shortcutWindow) {
            return panel
        }

        if let responder,
           let focusOwner = BrowserWindowPortalRegistry.focusOwner(
               for: responder,
               in: shortcutWindow
           ) {
            switch focusOwner {
            case .search(let panelId):
                if let panel = shortcutBrowserPanel(panelId: panelId, in: shortcutWindow) {
                    return panel
                }
            case .page(let webView):
                if let panel = shortcutBrowserPanel(webView: webView) {
                    return panel
                }
            case .designComposer, .omnibarSuggestions, .inspector, .otherChrome:
                break
            }
        }

        if let webView = shortcutOwningWebView(for: responder) {
            return shortcutBrowserPanel(webView: webView)
        }

        if let panel = shortcutFocusedBrowserPanel(in: shortcutWindow) {
            return panel
        }

        return nil
    }

    /// Resolves the browser that owns command/menu focus without requiring the
    /// original key event. This is captured before overlays or menu tracking can
    /// move AppKit's first responder.
    func focusedBrowserPanelForAction(
        in preferredWindow: NSWindow?
    ) -> BrowserPanel? {
        guard let window = preferredWindow ?? NSApp.keyWindow
            ?? NSApp.mainWindow else {
            return nil
        }
        let responder = window.firstResponder
        if let dockBrowser = shortcutActiveWindowDockBrowserPanel(
            in: window
        ) {
            return dockBrowser
        }
        if responder.cmuxStrictOwningGhosttyView() != nil {
            return nil
        }
        if let addressBarPanelId = focusedBrowserAddressBarPanelId(),
           browserOmnibarPanelId(for: responder) == addressBarPanelId,
           let panel = shortcutBrowserPanel(
               panelId: addressBarPanelId,
               in: window
           ) {
            return panel
        }
        if let responder,
           let focusOwner = BrowserWindowPortalRegistry.focusOwner(
               for: responder,
               in: window
           ) {
            switch focusOwner {
            case .search(let panelId):
                if let panel = shortcutBrowserPanel(panelId: panelId, in: window) {
                    return panel
                }
            case .page(let webView):
                if let panel = shortcutBrowserPanel(webView: webView) {
                    return panel
                }
            case .designComposer, .omnibarSuggestions, .inspector, .otherChrome:
                break
            }
        }
        if let webView = shortcutOwningWebView(for: responder),
           let panel = shortcutBrowserPanel(webView: webView) {
            return panel
        }
        if cmuxIsLikelyWebInspectorResponder(responder) {
            return shortcutWebInspectorFocusedBrowserPanel(in: window)
        }
        return shortcutFocusedBrowserPanel(in: window)
    }

    /// Whether the keystroke's first responder is owned by a browser panel's web
    /// view (the page itself or an editable element / field editor inside it), as
    /// opposed to a browser panel merely being the selected pane while chrome — the
    /// right sidebar, address bar, or find bar — holds keyboard focus. Scoped to
    /// browser-panel web views (not the diff viewer / markdown renderer) so the
    /// browser document-editing bypass only fires on genuine browser web-content
    /// focus and the default Cmd+I (Show Notifications) keeps working otherwise
    /// (issue #6776).
    func shortcutEventFirstResponderOwnsBrowserWebView(_ event: NSEvent) -> Bool {
        shortcutEventBrowserWebView(event) != nil
    }

    /// Returns the focused browser web view that owns an event's responder
    /// chain, excluding browser chrome such as the address/find bars and Web
    /// Inspector responders, which must retain their own keyboard handling.
    func shortcutEventBrowserWebView(_ event: NSEvent) -> CmuxWebView? {
        let shortcutWindow = shortcutResolvedEventWindow(event) ?? NSApp.keyWindow ?? NSApp.mainWindow
        guard let shortcutWindow,
              let responder = shortcutWindow.firstResponder else {
            return nil
        }

        if let cached = event.cmuxBrowserWebViewCache,
           cached.matches(window: shortcutWindow, responder: responder) {
            return cached.webView
        }

        let webView: CmuxWebView? = {
            guard browserOmnibarPanelId(for: responder) == nil else {
                return nil
            }

            // Portal-hosted browser chrome is a sibling of the page. Resolve
            // the direct slot owner first so the hot path never scans every
            // browser slot and never guesses that a chrome control belongs to
            // the page.
            if let focusOwner = BrowserWindowPortalRegistry.focusOwner(
                for: responder,
                in: shortcutWindow
            ) {
                guard case .page(let portalWebView) = focusOwner,
                      isBrowserPanelWebView(portalWebView),
                      !shortcutResponderIsInspector(
                          responder,
                          in: portalWebView
                      ) else {
                    return nil
                }
                return portalWebView
            }

            // Non-portal browser surfaces (including popup panels) use their
            // direct responder chain. The strict ownership check prevents a
            // sibling chrome view from being mapped to the page by the legacy
            // recovery resolver.
            guard let directWebView = shortcutOwningWebView(for: responder) as? CmuxWebView,
                  isBrowserPanelWebView(directWebView),
                  shortcutResponderBelongs(to: directWebView, responder: responder),
                  !shortcutResponderIsInspector(responder, in: directWebView) else {
                return nil
            }
            return directWebView
        }()

        event.cmuxBrowserWebViewCache = ShortcutEventBrowserWebViewCache(
            eventWindow: shortcutWindow,
            firstResponder: responder,
            webView: webView
        )
        return webView
    }

    private func shortcutResponderBelongs(
        to webView: WKWebView,
        responder: NSResponder
    ) -> Bool {
        if responder === webView {
            return true
        }
        if let view = responder as? NSView {
            return view.isDescendant(of: webView)
        }
        if let fieldEditor = responder as? NSTextView,
           fieldEditor.isFieldEditor,
           let ownerView = cmuxFieldEditorOwnerView(fieldEditor),
           (ownerView === webView || ownerView.isDescendant(of: webView)) {
            return true
        }

        var current = responder.nextResponder
        while let next = current {
            if next === webView {
                return true
            }
            if let view = next as? NSView,
               (view === webView || view.isDescendant(of: webView)) {
                return true
            }
            current = next.nextResponder
        }
        return false
    }

    private func shortcutResponderIsInspector(
        _ responder: NSResponder,
        in webView: WKWebView
    ) -> Bool {
        if cmuxIsLikelyWebInspectorResponder(responder) {
            return true
        }
        guard let inspectorWebView = webView.cmuxInspectorFrontendWebView() else {
            return false
        }
        return shortcutResponderBelongs(to: inspectorWebView, responder: responder)
    }

    private func shortcutFocusedBrowserPanel(in window: NSWindow?) -> BrowserPanel? {
        if let window {
            guard let context = shortcutMainWindowContext(in: window) else {
                return nil
            }
            if let windowDock = existingWindowDock(forWindowId: context.windowId) {
                if let panel = windowDock.browserPanel(owning: window.firstResponder, in: window) {
                    return panel
                }
            }
            if let panel = context.tabManager.selectedWorkspace?
                .dockBrowserPanel(owning: window.firstResponder, in: window) {
                return panel
            }
            if context.keyboardFocusCoordinator.activeRightSidebarMode == .dock {
                guard let windowDock = existingWindowDock(
                    forWindowId: context.windowId
                ),
                let focusedPanelId = windowDock.focusedPanelId else {
                    return nil
                }
                return windowDock.browserPanel(for: focusedPanelId)
            }
            return context.tabManager.focusedWorkspaceBrowserPanel
        }

        return tabManager?.focusedWorkspaceBrowserPanel
    }

    /// The focus coordinator is authoritative while the Dock owns keyboard
    /// focus. AppKit can briefly leave the previous main terminal as first
    /// responder during portal reparenting, which must not hide the selected
    /// Dock browser from browser commands.
    private func shortcutActiveWindowDockBrowserPanel(
        in window: NSWindow
    ) -> BrowserPanel? {
        guard let context = shortcutMainWindowContext(in: window),
              context.keyboardFocusCoordinator.activeRightSidebarMode == .dock,
              let dock = existingWindowDock(forWindowId: context.windowId),
              let panelId = dock.focusedPanelId else {
            return nil
        }
        return dock.browserPanel(for: panelId)
    }

    private func shortcutFocusedSimulatorPanel(in window: NSWindow?) -> SimulatorPanel? {
        guard let window, let responder = window.firstResponder else { return nil }
        if let context = shortcutMainWindowContext(in: window),
           let dock = existingWindowDock(forWindowId: context.windowId) {
            if let panelId = dock.focusedPanelId,
               let panel = dock.panels[panelId] as? SimulatorPanel,
               panel.ownedFocusIntent(for: responder, in: window) != nil {
                return panel
            }
        }
        guard let workspace = shortcutContextTabManager(in: window)?.selectedWorkspace else {
            return nil
        }
        if let panelId = workspace.focusedPanelId,
           let panel = workspace.panels[panelId] as? SimulatorPanel,
           panel.ownedFocusIntent(for: responder, in: window) != nil {
            return panel
        }
        return nil
    }

    private func shortcutWebInspectorFocusedBrowserPanel(in window: NSWindow?) -> BrowserPanel? {
        let responder = window?.firstResponder ?? NSApp.keyWindow?.firstResponder ?? NSApp.mainWindow?.firstResponder
        guard cmuxIsLikelyWebInspectorResponder(responder) else { return nil }

        if let window,
           let context = mainWindowContexts[ObjectIdentifier(window)] ??
               mainWindowContexts.values.first(where: { $0.window === window }) {
            return shortcutFocusedBrowserPanel(in: context.window ?? window)
        }

        return shortcutFocusedBrowserPanel(in: window)
    }

    private func shortcutResolvedEventWindow(_ event: NSEvent) -> NSWindow? {
        if event.windowNumber > 0,
           let window = NSApp.window(withWindowNumber: event.windowNumber) {
            return window
        }
        return event.window
    }

    private func shortcutBrowserPanel(panelId: UUID, in window: NSWindow?) -> BrowserPanel? {
        if let context = shortcutMainWindowContext(in: window),
           let panel = existingWindowDock(forWindowId: context.windowId)?.browserPanel(for: panelId) {
            return panel
        }
        if let panel = windowDockContainingPanel(panelId)?.browserPanel(for: panelId) {
            return panel
        }
        guard let workspace = shortcutContextTabManager(in: window)?.selectedWorkspace else {
            return nil
        }
        return workspace.browserPanelIncludingDock(for: panelId)
    }

    private func shortcutBrowserPanel(webView: WKWebView) -> BrowserPanel? {
        browserPanel(owning: webView)
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
