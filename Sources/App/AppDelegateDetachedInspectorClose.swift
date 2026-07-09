import AppKit

@MainActor
extension AppDelegate {
    @discardableResult
    func closeDetachedInspectorWindowForCloseShortcut(event: NSEvent, panels: [BrowserPanel]) -> Bool {
        for window in closeShortcutWindowCandidates(event: event) {
            for panel in panels {
                if panel.closeDeveloperToolsFromDetachedInspectorWindowUserAction(
                    window,
                    source: "shortcut.\(NSWindow.keyDescription(event))"
                ) {
#if DEBUG
                    cmuxDebugLog(
                        "browser.devtools detachedClose.shortcut panel=\(panel.id.uuidString.prefix(5)) " +
                        "event=\(NSWindow.keyDescription(event)) window=\(window.windowNumber)"
                    )
#endif
                    return true
                }
            }
        }
        return false
    }

    func closeShortcutWindowCandidates(event: NSEvent) -> [NSWindow] {
        var seen = Set<Int>()
        var windows: [NSWindow] = []
        func append(_ candidates: [NSWindow?]) {
            for candidate in candidates {
                guard let candidate else { continue }
                let windowNumber = candidate.windowNumber
                guard seen.insert(windowNumber).inserted else { continue }
                windows.append(candidate)
            }
        }

        append([
            shortcutRoutingKeyWindow,
            NSApp.keyWindow,
            shortcutRoutingActiveWindow,
            NSApp.mainWindow,
        ])
        append([
            event.window,
            event.windowNumber > 0 ? NSApp.window(withWindowNumber: event.windowNumber) : nil,
        ])
        return windows
    }

    func hasDetachedInspectorWindowForCloseShortcut(event: NSEvent, panels: [BrowserPanel]) -> Bool {
        for window in closeShortcutWindowCandidates(event: event) {
            for panel in panels where panel.ownsDetachedDeveloperToolsWindow(window) {
                return true
            }
        }
        return false
    }

    func handleDetachedInspectorCloseShortcutOutsideMainContext(event: NSEvent) -> Bool {
        guard isCloseTabShortcutEventOrChordPrefix(event) else { return false }
        let panels = allBrowserPanelsForInspectorWindowClose()
        if matchConfiguredShortcut(event: event, action: .closeTab) {
            return closeDetachedInspectorWindowForCloseShortcut(event: event, panels: panels)
        }
        guard hasDetachedInspectorWindowForCloseShortcut(event: event, panels: panels) else { return false }
        if activeConfiguredShortcutChordPrefixForCurrentEvent == nil,
           armConfiguredShortcutChordIfNeeded(event: event, actions: [.closeTab]) {
            return true
        }
        return false
    }

    func isCloseTabShortcutEventOrChordPrefix(_ event: NSEvent) -> Bool {
        if matchConfiguredShortcut(event: event, action: .closeTab) {
            return true
        }
        guard activeConfiguredShortcutChordPrefixForCurrentEvent == nil else { return false }
        let closeTabShortcut = KeyboardShortcutSettings.shortcut(for: .closeTab)
        guard closeTabShortcut.hasChord else { return false }
        return matchShortcutStroke(event: event, stroke: closeTabShortcut.firstStroke)
    }

    @discardableResult
    func handleDetachedInspectorWindowCloseAction(
        action: Selector,
        target: Any?,
        sender: Any?
    ) -> Bool {
        guard Thread.isMainThread else { return false }

        return MainActor.assumeIsolated {
            guard Self.shouldInterceptWindowCloseAction(
                action,
                target: target,
                sender: sender
            ) else { return false }
            guard let window = Self.actionWindow(
                target: target,
                sender: sender,
                allowFallback: Self.allowsWindowFallback(for: action)
            ) else { return false }

            for panel in allBrowserPanelsForInspectorWindowClose() {
                if panel.closeDeveloperToolsFromDetachedInspectorWindowUserAction(
                    window,
                    source: "sendAction.\(NSStringFromSelector(action))"
                ) {
#if DEBUG
                    cmuxDebugLog(
                        "browser.devtools detachedClose.action panel=\(panel.id.uuidString.prefix(5)) " +
                        "action=\(NSStringFromSelector(action)) window=\(window.windowNumber)"
                    )
#endif
                    return true
                }
            }

            return false
        }
    }

    static func shouldInterceptWindowCloseAction(
        _ action: Selector,
        target: Any?,
        sender: Any?
    ) -> Bool {
        switch NSStringFromSelector(action) {
        case "__close", "performClose:":
            return true
        case "close", "close:":
            return actionWindow(target: target, sender: sender, allowFallback: false) != nil
        default:
            return false
        }
    }

    static func allowsWindowFallback(for action: Selector) -> Bool {
        switch NSStringFromSelector(action) {
        case "__close", "performClose:":
            return true
        default:
            return false
        }
    }

    static func actionWindow(
        target: Any?,
        sender: Any?,
        allowFallback: Bool = true
    ) -> NSWindow? {
        if let window = target as? NSWindow {
            return window
        }
        if let window = sender as? NSWindow {
            return window
        }
        if let view = sender as? NSView {
            return view.window
        }
        if let cell = sender as? NSCell {
            return cell.controlView?.window
        }
        if target == nil, sender is NSMenuItem {
            return AppDelegate.shared?.shortcutRoutingActiveWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        }
        return allowFallback ? (AppDelegate.shared?.shortcutRoutingActiveWindow ?? NSApp.keyWindow ?? NSApp.mainWindow) : nil
    }

    func allBrowserPanelsForInspectorWindowClose() -> [BrowserPanel] {
        var candidateManagers: [TabManager] = []
        var seenManagers = Set<ObjectIdentifier>()
        var panels: [BrowserPanel] = []
        var seenPanels = Set<ObjectIdentifier>()

        func appendCandidate(_ manager: TabManager?) {
            guard let manager else { return }
            let identifier = ObjectIdentifier(manager)
            guard seenManagers.insert(identifier).inserted else { return }
            candidateManagers.append(manager)
        }

        appendCandidate(tabManager)
        for context in registeredMainWindows {
            appendCandidate(context.tabManager)
        }
        for route in recoverableMainWindowRoutes() {
            appendCandidate(route.tabManager)
        }

        func appendPanel(_ panel: any Panel) {
            guard let browserPanel = panel as? BrowserPanel else { return }
            let identifier = ObjectIdentifier(browserPanel)
            guard seenPanels.insert(identifier).inserted else { return }
            panels.append(browserPanel)
        }

        for manager in candidateManagers {
            for workspace in manager.tabs {
                for panel in workspace.panels.values {
                    appendPanel(panel)
                }
                // Workspace Docks keep their own panel store; include their
                // browser panels so detached-inspector close routing and focus
                // handoff cover Dock-hosted DevTools too.
                workspace._dockSplit?.forEachPanel { _, panel in
                    appendPanel(panel)
                }
            }
        }
        for context in registeredMainWindows {
            existingWindowDock(forWindowId: context.windowId)?.forEachPanel { _, panel in
                appendPanel(panel)
            }
        }

        return panels
    }

}

extension NSWindow {
    static func keyDescription(_ event: NSEvent) -> String {
        var parts: [String] = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { parts.append("Cmd") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.option) { parts.append("Opt") }
        if flags.contains(.control) { parts.append("Ctrl") }
        let chars: String
        if event.type == .keyDown || event.type == .keyUp {
            chars = event.charactersIgnoringModifiers ?? "?"
        } else {
            chars = String(describing: event.type)
        }
        parts.append("'\(chars)'(\(event.keyCode))")
        return parts.joined(separator: "+")
    }
}
