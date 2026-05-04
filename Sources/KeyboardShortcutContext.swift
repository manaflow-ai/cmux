import AppKit
import WebKit

struct ShortcutEventFocusContext {
    let browserPanel: BrowserPanel?
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
        case rightSidebarFocus

        var isAlwaysAvailable: Bool {
            self == .application
        }

        func isAvailable(focusedBrowserPanel: Bool, rightSidebarFocused: Bool) -> Bool {
            switch self {
            case .application:
                return true
            case .nonBrowserPanel:
                return !focusedBrowserPanel && !rightSidebarFocused
            case .browserPanel:
                return focusedBrowserPanel
            case .rightSidebarFocus:
                return rightSidebarFocused
            }
        }

        func isAvailable(_ context: ShortcutEventFocusContext) -> Bool {
            isAvailable(focusedBrowserPanel: context.browserPanel != nil, rightSidebarFocused: context.rightSidebarFocused)
        }

        func overlaps(_ other: ShortcutContext) -> Bool {
            if self == .application || other == .application {
                return true
            }
            return self == other
        }
    }

    var shortcutContext: ShortcutContext {
        switch self {
        case .switchRightSidebarToFiles, .switchRightSidebarToFind, .switchRightSidebarToSessions, .switchRightSidebarToFeed, .switchRightSidebarToDock:
            return .rightSidebarFocus
        case .renameTab, .renameWorkspace:
            return .nonBrowserPanel
        case .browserBack, .browserForward, .browserReload, .toggleBrowserDeveloperTools, .showBrowserJavaScriptConsole,
             .browserZoomIn, .browserZoomOut, .browserZoomReset:
            return .browserPanel
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

    func shortcutEventFocusContext(_ event: NSEvent) -> ShortcutEventFocusContext {
        if let cache = shortcutEventFocusContextCache, cache.event === event {
            return cache.context
        }

        let shortcutWindow = shortcutResolvedEventWindow(event) ?? NSApp.keyWindow ?? NSApp.mainWindow
        let context = ShortcutEventFocusContext(
            browserPanel: shortcutEventFocusedBrowserPanel(event) ?? shortcutWebInspectorFocusedBrowserPanel(in: shortcutWindow),
            rightSidebarFocused: shortcutWindow.map { shouldRouteRightSidebarModeShortcut(in: $0) } ?? false
        )
        shortcutEventFocusContextCache = ShortcutEventFocusContextCache(event: event, context: context)
        return context
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

        return nil
    }

    private func shortcutWebInspectorFocusedBrowserPanel(in window: NSWindow?) -> BrowserPanel? {
        let responder = window?.firstResponder ?? NSApp.keyWindow?.firstResponder ?? NSApp.mainWindow?.firstResponder
        guard cmuxIsLikelyWebInspectorResponder(responder) else { return nil }

        if let window,
           let context = mainWindowContexts[ObjectIdentifier(window)] ??
               mainWindowContexts.values.first(where: { $0.window === window }) {
            return context.tabManager.focusedBrowserPanel
        }

        return tabManager?.focusedBrowserPanel
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
