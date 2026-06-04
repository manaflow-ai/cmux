import AppKit
import WebKit

struct ShortcutEventFocusContext {
    let browserPanel: BrowserPanel?
    let markdownPanel: MarkdownPanel?
    let rightSidebarFocused: Bool
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
        case .renameTab, .renameWorkspace, .sendCtrlFToTerminal:
            return .nonBrowserPanel
        case .browserBack, .browserForward, .browserReload, .toggleBrowserDeveloperTools, .showBrowserJavaScriptConsole,
             .browserZoomIn, .browserZoomOut, .browserZoomReset, .toggleBrowserFocusMode:
            return .browserPanel
        case .markdownZoomIn, .markdownZoomOut, .markdownZoomReset:
            return .markdownPanel
        default:
            return .application
        }
    }
}

extension Notification.Name {
    static let debugBrowserReloadShortcutInvoked = Notification.Name("cmux.debugBrowserReloadShortcutInvoked")
}

extension AppDelegate {
    func reloadBrowserPanelForShortcut(_ panel: BrowserPanel) {
#if DEBUG
        NotificationCenter.default.post(name: .debugBrowserReloadShortcutInvoked, object: panel)
#endif
        panel.reload()
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
        let context = ShortcutEventFocusContext(
            browserPanel: browserPanel,
            // Only treat a markdown panel as focused when no browser panel owns
            // the event, so a focused browser never routes markdown shortcuts.
            markdownPanel: browserPanel == nil ? shortcutFocusedMarkdownPanel(in: shortcutWindow) : nil,
            rightSidebarFocused: shortcutWindow.map { shouldRouteRightSidebarModeShortcut(in: $0) } ?? false
        )
        shortcutEventFocusContextCache = ShortcutEventFocusContextCache(event: event, context: context)
        return context
    }

    private func shortcutFocusedMarkdownPanel(in window: NSWindow?) -> MarkdownPanel? {
        // `focusedMarkdownPanel` is already gated to preview mode, where the
        // rendered viewer responds to zoom (the raw text editor does not).
        if let window {
            guard let context = mainWindowContexts[ObjectIdentifier(window)] ??
                mainWindowContexts.values.first(where: { $0.window === window }) else {
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
            guard let context = mainWindowContexts[ObjectIdentifier(window)] ??
                mainWindowContexts.values.first(where: { $0.window === window }) else {
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
           let context = mainWindowContexts[ObjectIdentifier(window)] ??
               mainWindowContexts.values.first(where: { $0.window === window }) {
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
