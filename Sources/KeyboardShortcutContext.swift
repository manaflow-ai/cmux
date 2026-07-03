import AppKit
import CmuxSettings
import WebKit

struct ShortcutEventFocusContext {
    let browserPanel: BrowserPanel?
    let markdownPanel: MarkdownPanel?
    let filePreviewTextEditorFocused: Bool
    let rightSidebarFocused: Bool
    /// The full context snapshot a ``ShortcutWhenClause`` evaluates against.
    let shortcutContext: ShortcutContext

    /// Projects the runtime focus snapshot onto the atoms a
    /// ``ShortcutWhenClause`` evaluates against.
    var focusState: ShortcutFocusState {
        ShortcutFocusState(
            browser: browserPanel != nil,
            markdown: markdownPanel != nil,
            sidebar: rightSidebarFocused,
            filePreviewTextEditor: filePreviewTextEditorFocused
        )
    }
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
        let browserPanel = shortcutEventFocusedBrowserPanel(event) ?? shortcutWebInspectorFocusedBrowserPanel(in: shortcutWindow)
        // Only treat a markdown panel as focused when no browser panel owns the
        // event, so a focused browser never routes markdown shortcuts.
        let markdownPanel = browserPanel == nil ? shortcutFocusedMarkdownPanel(in: shortcutWindow) : nil
        let filePreviewTextEditorFocused = browserPanel == nil && markdownPanel == nil
            ? shortcutFocusedFilePreviewTextEditor(in: shortcutWindow)
            : false
        let rightSidebarFocused = shortcutWindow.map { shouldRouteRightSidebarModeShortcut(in: $0) } ?? false
        let focusState = ShortcutFocusState(
            browser: browserPanel != nil,
            markdown: markdownPanel != nil,
            sidebar: rightSidebarFocused,
            filePreviewTextEditor: filePreviewTextEditorFocused
        )
        let context = ShortcutEventFocusContext(
            browserPanel: browserPanel,
            markdownPanel: markdownPanel,
            filePreviewTextEditorFocused: filePreviewTextEditorFocused,
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
                context.setInt(ShortcutContextKnownKey.paneCount.rawValue, workspace.bonsplitController.allPaneIds.count)
                context.setBool(ShortcutContextKnownKey.workspaceCanvasLayout.rawValue, workspace.layoutMode == .canvas)
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

    func shortcutEventFocusedBrowserPanel(_ event: NSEvent) -> BrowserPanel? {
        guard let shortcutWindow = shortcutResolvedEventWindow(event) ?? NSApp.keyWindow ?? NSApp.mainWindow else {
            return nil
        }

        let responder = shortcutWindow.firstResponder
        if cmuxOwningGhosttyView(for: responder) != nil {
            return nil
        }

        if let panelId = focusedBrowserAddressBarPanelIdForShortcutEvent(event),
           let panel = shortcutBrowserPanel(panelId: panelId, in: shortcutWindow) {
            return panel
        }

        if let responder,
           let panelId = BrowserWindowPortalRegistry.searchOverlayPanelId(for: responder, in: shortcutWindow),
           let panel = shortcutBrowserPanel(panelId: panelId, in: shortcutWindow) {
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

    /// Whether the keystroke's first responder is owned by a browser panel's web
    /// view (the page itself or an editable element / field editor inside it), as
    /// opposed to a browser panel merely being the selected pane while chrome — the
    /// right sidebar, address bar, or find bar — holds keyboard focus. Scoped to
    /// browser-panel web views (not the diff viewer / markdown renderer) so the
    /// browser document-editing bypass only fires on genuine browser web-content
    /// focus and the default Cmd+I (Show Notifications) keeps working otherwise
    /// (issue #6776).
    func shortcutEventFirstResponderOwnsBrowserWebView(_ event: NSEvent) -> Bool {
        let shortcutWindow = shortcutResolvedEventWindow(event) ?? NSApp.keyWindow ?? NSApp.mainWindow
        guard let responder = shortcutWindow?.firstResponder,
              let webView = shortcutOwningWebView(for: responder) else {
            return false
        }
        return shortcutBrowserPanel(webView: webView) != nil
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
                if context.keyboardFocusCoordinator.activeRightSidebarMode == .dock,
                   let focusedPanelId = windowDock.focusedPanelId,
                   let panel = windowDock.browserPanel(for: focusedPanelId) {
                    return panel
                }
            }
            if let panel = context.tabManager.selectedWorkspace?
                .dockBrowserPanel(owning: window.firstResponder, in: window) {
                return panel
            }
            return context.tabManager.focusedBrowserPanel
        }

        return tabManager?.focusedBrowserPanel
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
        // Fast path: the portal registry maps the webView to its owning pane id
        // in O(1). Resolve that id against the candidate workspaces (main area +
        // Dock) instead of comparing every panel's webView on each keystroke. A
        // focused browser webView delivering a shortcut is always portal-hosted,
        // so this covers the common case without the full panel scan.
        if let context = BrowserWindowPortalRegistry.paneDropContext(for: webView) {
            if let panel = windowDockContainingPanel(context.panelId)?.browserPanel(for: context.panelId) {
                return panel
            }
            for manager in shortcutCandidateTabManagers() {
                for workspace in manager.tabs {
                    if let panel = workspace.browserPanelIncludingDock(for: context.panelId) {
                        return panel
                    }
                }
            }
        }
        // Fallback for webViews not registered in a portal: scan candidate panels.
        for dock in existingWindowDocks {
            for panel in dock.panels.values {
                guard let browserPanel = panel as? BrowserPanel,
                      browserPanel.webView === webView else {
                    continue
                }
                return browserPanel
            }
        }
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
        let candidates = [tabManager] + mainWindowContexts.values.map { Optional($0.tabManager) }
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
