import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSettingsUI
import CmuxSocketControl
import CmuxUpdater
import CmuxUpdaterUI
import SwiftUI
import Bonsplit
import CMUXWorkstream
import CoreServices
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime
import Darwin
import CmuxFoundation


// MARK: - Shortcut monitor and configured shortcut key handling
extension AppDelegate {
    func installShortcutMonitor() {
        // Local monitor only receives events when app is active (not global)
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged, .systemDefined]
        ) { [weak self] event in
            guard let self else { return event }
            if ShortcutRecorderEventRouter.dispatchActiveRecordingEvent(
                event,
                preferredWindow: event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            ) {
                return nil
            }
            if event.type == .systemDefined {
                return event
            }
            if event.type == .keyDown {
#if DEBUG
                let phaseTotalStart = ProcessInfo.processInfo.systemUptime
                let preludeStart = ProcessInfo.processInfo.systemUptime
                var preludeMs: Double = 0
                var shortcutMs: Double = 0
                CmuxTypingTiming.logEventDelay(path: "appMonitor", event: event)
                let shortcutMonitorTraceEnabled =
                    ProcessInfo.processInfo.environment["CMUX_SHORTCUT_MONITOR_TRACE"] == "1"
                    || UserDefaults.standard.bool(forKey: "cmuxShortcutMonitorTrace")
                if shortcutMonitorTraceEnabled {
                    let frType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                    cmuxDebugLog(
                        "monitor.keyDown: \(NSWindow.keyDescription(event)) fr=\(frType) addrBarId=\(self.browserAddressBarFocusedPanelId?.uuidString.prefix(8) ?? "nil") \(self.debugShortcutRouteSnapshot(event: event))"
                    )
                }
                if let probeKind = self.developerToolsShortcutProbeKind(event: event) {
                    self.logDeveloperToolsShortcutSnapshot(phase: "monitor.pre.\(probeKind)", event: event)
                }
                preludeMs = (ProcessInfo.processInfo.systemUptime - preludeStart) * 1000.0
                let shortcutTimingStart = CmuxTypingTiming.start()
#endif
                let shortcutStart = ProcessInfo.processInfo.systemUptime
                let handledByShortcut = cmuxCloseFocusedTerminalFindForEscape(event: event, appDelegate: self) || self.handleCustomShortcut(event: event)
#if DEBUG
                shortcutMs = (ProcessInfo.processInfo.systemUptime - shortcutStart) * 1000.0
                CmuxTypingTiming.logDuration(
                    path: "appMonitor.handleCustomShortcut",
                    startedAt: shortcutTimingStart,
                    event: event,
                    extra: "handled=\(handledByShortcut ? 1 : 0)"
                )
                let shortcutElapsedMs = (ProcessInfo.processInfo.systemUptime - shortcutStart) * 1000.0
                self.logSlowShortcutMonitorLatencyIfNeeded(
                    event: event,
                    handledByShortcut: handledByShortcut,
                    elapsedMs: shortcutElapsedMs
                )
                let totalMs = (ProcessInfo.processInfo.systemUptime - phaseTotalStart) * 1000.0
                CmuxTypingTiming.logBreakdown(
                    path: "appMonitor.phase",
                    totalMs: totalMs,
                    event: event,
                    thresholdMs: 0.75,
                    parts: [
                        ("preludeMs", preludeMs),
                        ("shortcutMs", shortcutMs),
                    ],
                    extra: "handled=\(handledByShortcut ? 1 : 0)"
                )
#endif
                if handledByShortcut {
#if DEBUG
                    cmuxDebugLog("  → consumed by handleCustomShortcut")
#endif
                    return nil // Consume the event
                }
                return event // Pass through
            }
            self.handleBrowserOmnibarSelectionRepeatLifecycleEvent(event)
            if self.clearEscapeSuppressionForKeyUp(event: event, consumeIfSuppressed: true) {
                return nil
            }
            return event
        }
    }

    func installShortcutDefaultsObserver() {
        guard shortcutDefaultsObserver == nil else { return }
        shortcutDefaultsObserver = NotificationCenter.default.addObserver(
            forName: KeyboardShortcutSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.handleShortcutDefaultsDidChange()
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.handleShortcutDefaultsDidChange()
                }
            }
        }
    }

    private func handleShortcutDefaultsDidChange() {
        clearConfiguredShortcutChordState()
        scheduleReloadConfigurationMenuItemRefresh()
        scheduleSplitButtonTooltipRefreshAcrossWorkspaces()
    }

    func currentConfiguredShortcutChordActions() -> [KeyboardShortcutSettings.Action] {
        KeyboardShortcutSettings.Action.allCases.filter { action in
            // System-wide hotkeys are dispatched via Carbon RegisterEventHotKey
            // and never routed through AppKit's local key handler. If a managed
            // cmux.json entry somehow stores one as a chord, arming the prefix
            // here would swallow the first stroke and leave the second one
            // orphaned, breaking that keystroke for the focused terminal/browser
            // input.
            guard action != .showHideAllWindows && action != .globalSearch else { return false }
            guard !action.isBrowserContentShortcut else { return false }
            return KeyboardShortcutSettings.shortcut(for: action).hasChord
        }
    }

    func clearConfiguredShortcutChordState() {
        pendingConfiguredShortcutChord = nil
        activeConfiguredShortcutChordPrefixForCurrentEvent = nil
    }

    /// Coalesce shortcut-default changes and refresh on the next runloop turn to
    /// avoid mutating Bonsplit/SwiftUI-observed state during an active update pass.
    private func scheduleSplitButtonTooltipRefreshAcrossWorkspaces() {
        guard !splitButtonTooltipRefreshScheduled else { return }
        splitButtonTooltipRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.splitButtonTooltipRefreshScheduled = false
            self.refreshSplitButtonTooltipsAcrossWorkspaces()
        }
    }

    private func refreshSplitButtonTooltipsAcrossWorkspaces() {
        var refreshedManagers: Set<ObjectIdentifier> = []
        if let manager = tabManager {
            manager.refreshSplitButtonTooltips()
            refreshedManagers.insert(ObjectIdentifier(manager))
        }
        for context in mainWindowContexts.values {
            let manager = context.tabManager
            let identifier = ObjectIdentifier(manager)
            guard refreshedManagers.insert(identifier).inserted else { continue }
            manager.refreshSplitButtonTooltips()
        }
    }

    func handleQuitShortcutWarning() -> Bool {
        if !QuitWarningSettings.shouldShowConfirmation(
            isQuitWarningConfirmed: false,
            hasDirtyWorkspaces: hasQuitConfirmationDirtyWorkspaces(),
            buildFlavor: .current
        ) {
            NSApp.terminate(nil)
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "dialog.quitCmux.title", defaultValue: "Quit cmux?")
        alert.informativeText = String(localized: "dialog.quitCmux.message", defaultValue: "This will close all windows and workspaces.")
        alert.addButton(withTitle: String(localized: "dialog.quitCmux.quit", defaultValue: "Quit"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "dialog.dontWarnCmdQ", defaultValue: "Don't warn again for Cmd+Q")

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            QuitWarningSettings.setEnabled(false)
        }

        if response == .alertFirstButtonReturn {
            // Mark as confirmed so applicationShouldTerminate does not show a
            // second alert when NSApp.terminate re-enters the delegate callback.
            isQuitWarningConfirmed = true
            NSApp.terminate(nil)
        }
        return true
    }

    func promptRenameSelectedWorkspace() -> Bool {
        guard let tabManager,
              let tabId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
            NSSound.beep()
            return false
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "dialog.renameWorkspace.title", defaultValue: "Rename Workspace")
        alert.informativeText = String(localized: "dialog.renameWorkspace.message", defaultValue: "Enter a custom name for this workspace.")
        let input = NSTextField(string: tab.customTitle ?? tab.title)
        input.placeholderString = String(localized: "dialog.renameWorkspace.placeholder", defaultValue: "Workspace name")
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "common.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return true }
        tabManager.setCustomTitle(tabId: tab.id, title: input.stringValue)
        return true
    }

    /// Allow AppKit-backed browser surfaces (WKWebView) to route non-menu shortcuts
    /// through the same app-level shortcut handler used by the local key monitor.
    @discardableResult
    func handleBrowserSurfaceKeyEquivalent(_ event: NSEvent) -> Bool {
        handleConfiguredShortcutKeyEquivalent(event)
    }

    /// Route AppKit key-equivalent fallbacks through the same configured shortcut
    /// dispatcher as the local key monitor before any stale menu item can run.
    @discardableResult
    func handleConfiguredShortcutKeyEquivalent(_ event: NSEvent) -> Bool {
        handleCustomShortcut(event: event)
    }

    /// WebKit can consume the configured Find shortcut as a browser find key equivalent before SwiftUI
    /// command actions run. Keep this pre-menu route narrow so normal menu-backed
    /// browser shortcuts such as New Workspace, Close Tab, and Reload Page still use AppKit.
    @discardableResult
    func handleBrowserSurfaceKeyEquivalentBeforeMainMenu(_ event: NSEvent) -> Bool {
        if matchConfiguredShortcut(event: event, action: .find) {
            let shortcutWindow = resolvedShortcutEventWindow(event)
            cmuxRememberFindSelectionBeforePanelFocusMove(tabManager: tabManager, window: shortcutWindow ?? NSApp.keyWindow); return performFindShortcutInActiveMainWindow(preferredWindow: shortcutWindow)
        }
        if matchConfiguredShortcut(event: event, action: .findInDirectory) {
            return focusFileSearchInActiveMainWindow(preferredWindow: resolvedShortcutEventWindow(event))
        }
        return false
    }

    @discardableResult
    func requestRenameWorkspaceViaCommandPalette(preferredWindow: NSWindow? = nil) -> Bool {
        let targetWindow = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        requestCommandPaletteRenameWorkspace(
            preferredWindow: targetWindow,
            source: "shortcut.renameWorkspace"
        )
        return true
    }

    @discardableResult
    func handleToggleFocusedWorkspaceGroupCollapsedShortcut(preferredWindow: NSWindow? = nil) -> Bool {
        let targetWindow = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        let resolvedTabManager: TabManager? = contextForMainWindow(targetWindow)?.tabManager ?? self.tabManager
        guard let tabManager = resolvedTabManager else { return false }
        guard let focusedId = tabManager.selectedTabId,
              let groupId = tabManager.tabs.first(where: { $0.id == focusedId })?.groupId else {
            // Don't consume the event when the focused workspace isn't in a
            // group — let the matched chord propagate (no React Grab
            // collision here, but stay consistent with the group-create
            // shortcut's fall-through policy).
            return false
        }
        tabManager.toggleWorkspaceGroupCollapsed(groupId: groupId)
        return true
    }

    @discardableResult
    func handleGroupSelectedWorkspacesShortcut(preferredWindow: NSWindow? = nil) -> Bool {
        // Resolve the TabManager for the preferred/key/main window first so
        // multi-window users get the group created in the window they were
        // looking at. Fall back to the app-level tabManager only if no window
        // context resolves.
        let targetWindow = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        let resolvedTabManager: TabManager? = contextForMainWindow(targetWindow)?.tabManager ?? self.tabManager
        guard let tabManager = resolvedTabManager else { return false }
        let selectedSet = tabManager.sidebarSelectedWorkspaceIds
        // sidebarSelectedWorkspaceIds is a Set; sort by tabs[] order so the
        // anchor is placed before the first sidebar-visible selected workspace
        // (createWorkspaceGroup uses the first child to position the anchor).
        let orderedSelectedIds: [UUID] = selectedSet.isEmpty
            ? []
            : tabManager.tabs.compactMap { selectedSet.contains($0.id) ? $0.id : nil }
        // Only consume the shortcut when there's an explicit sidebar
        // multi-selection. Anything ≤ 1 falls through so ⌘⇧G keeps working as
        // React Grab's default in browser/terminal contexts. A single-tab
        // group can still be created via right-click → New Group from
        // Workspace. `sidebarSelectedWorkspaceIds` is normally synced to the
        // focused workspace (clearSidebarMultiSelection sets it to a
        // singleton after keyboard nav), so the singleton case must be
        // treated the same as "no selection."
        guard orderedSelectedIds.count >= 2 else { return false }
        let candidateIds: [UUID] = orderedSelectedIds
        // Match the workspace context-menu eligibility filter so the shortcut
        // doesn't silently create an anchor-only group when every selected
        // target is already an existing group's anchor.
        let existingAnchorIds = Set(tabManager.workspaceGroups.map(\.anchorWorkspaceId))
        let eligibleIds: [UUID] = candidateIds.filter { id in
            tabManager.tabs.contains(where: { $0.id == id }) && !existingAnchorIds.contains(id)
        }
        guard eligibleIds.count >= 2 else {
            // Don't consume the event — let it propagate to the next handler
            // (e.g. toggleReactGrab on the default Cmd+Shift+G binding) so
            // the user gets the next-best action instead of a dead key. The
            // shortcut contract is "multi-select then ⌘⇧G"; single-workspace
            // groups are only created from the right-click context menu, so
            // a 2-row sidebar selection where only one survives the
            // pinned/anchor filter should also fall through.
            return false
        }
        // No name prompt: TabManager auto-names ("Group N"). Rename via the
        // header context menu.
        tabManager.createWorkspaceGroup(name: "", childWorkspaceIds: eligibleIds)
        return true
    }

    @discardableResult
    func requestEditWorkspaceDescriptionViaCommandPalette(preferredWindow: NSWindow? = nil) -> Bool {
        let targetWindow = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
#if DEBUG
        cmuxDebugLog(
            "shortcut.editWorkspaceDescription request target={\(debugWindowToken(targetWindow))} " +
            "fr=\(targetWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")"
        )
#endif
        requestCommandPaletteEditWorkspaceDescription(
            preferredWindow: targetWindow,
            source: "shortcut.editWorkspaceDescription"
        )
        return true
    }

#if DEBUG
    // Debug/test hook: allow socket-driven shortcut simulation to reuse the same shortcut routing
    // logic as the local NSEvent monitor, without relying on AppKit event monitor behavior for
    // synthetic NSEvents.
    func debugHandleCustomShortcut(event: NSEvent) -> Bool {
        handleCustomShortcut(event: event)
    }

    // Debug/test hook: mirrors local monitor routing (keyDown + keyUp lifecycle).
    func debugHandleShortcutMonitorEvent(event: NSEvent) -> Bool {
        if event.type == .systemDefined {
            return false
        }
        if event.type == .keyDown {
            return handleCustomShortcut(event: event)
        }
        handleBrowserOmnibarSelectionRepeatLifecycleEvent(event)
        return clearEscapeSuppressionForKeyUp(event: event, consumeIfSuppressed: true)
    }

    func debugMatchesConfiguredShortcut(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action
    ) -> Bool {
        matchConfiguredShortcut(event: event, action: action)
    }

    func debugResetShortcutRoutingStateForTesting() {
        clearConfiguredShortcutChordState()
        shortcutEventFocusContextCache = nil
    }

    func debugMarkCommandPaletteOpenPending(window: NSWindow) {
        markCommandPaletteOpenRequested(for: window)
    }

    @discardableResult
    func debugSetCommandPalettePendingOpenAge(window: NSWindow, age: TimeInterval) -> Bool {
        guard let windowId = mainWindowId(for: window) else { return false }
        commandPalettePendingOpenByWindowId[windowId] = true
        commandPaletteRecentRequestAtByWindowId[windowId] = ProcessInfo.processInfo.systemUptime - max(age, 0)
        return true
    }

    // Test hook: remap a window context under a detached window key so direct
    // ObjectIdentifier(window) lookups fail and fallback logic is exercised.
    @discardableResult
    func debugInjectWindowContextKeyMismatch(windowId: UUID) -> Bool {
        guard let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }),
              let window = context.window ?? windowForMainWindowId(windowId) else {
            return false
        }

        let detachedWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 16, height: 16),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        debugDetachedContextWindows.append(detachedWindow)

        let contextKeys = mainWindowContexts.compactMap { key, value in
            value === context ? key : nil
        }
        for key in contextKeys {
            mainWindowContexts.removeValue(forKey: key)
        }
        mainWindowContexts[ObjectIdentifier(detachedWindow)] = context
        context.window = window
        return true
    }
#endif

    func findButton(in view: NSView, titled title: String) -> NSButton? {
        if let button = view as? NSButton, button.title == title {
            return button
        }
        for subview in view.subviews {
            if let found = findButton(in: subview, titled: title) {
                return found
            }
        }
        return nil
    }

    func findStaticText(in view: NSView, equals text: String) -> Bool {
        if let field = view as? NSTextField, field.stringValue == text {
            return true
        }
        for subview in view.subviews {
            if findStaticText(in: subview, equals: text) {
                return true
            }
        }
        return false
    }

    @discardableResult
    func handleBrowserPopupCloseShortcutKeyEquivalent(event: NSEvent, popupWindow: NSWindow) -> Bool {
        guard event.type == .keyDown else {
            clearConfiguredShortcutChordState()
            return false
        }
        guard !KeyboardShortcutRecorderActivity.isAnyRecorderActive else {
            clearConfiguredShortcutChordState()
            return false
        }

        let configuredShortcutEventWindowNumber = configuredShortcutChordWindowNumber(for: event)
        if let pendingConfiguredShortcutChord,
           pendingConfiguredShortcutChord.windowNumber == configuredShortcutEventWindowNumber {
            activeConfiguredShortcutChordPrefixForCurrentEvent = pendingConfiguredShortcutChord.firstStroke
        } else {
            activeConfiguredShortcutChordPrefixForCurrentEvent = nil
        }
        pendingConfiguredShortcutChord = nil
        defer {
            activeConfiguredShortcutChordPrefixForCurrentEvent = nil
            clearShortcutEventFocusContextCache(for: event)
        }

        if matchConfiguredShortcut(event: event, action: .closeTab) {
#if DEBUG
            cmuxDebugLog("popup.panel.closeShortcut close")
#endif
            popupWindow.performClose(nil)
            return true
        }
        if activeConfiguredShortcutChordPrefixForCurrentEvent == nil,
           armConfiguredShortcutChordIfNeeded(event: event, actions: [.closeTab]) {
#if DEBUG
            cmuxDebugLog("popup.panel.closeShortcut armChord")
#endif
            return true
        }
        return false
    }

    func matchConfiguredShortcut(event: NSEvent, shortcut: StoredShortcut) -> Bool {
        guard !shortcut.isUnbound else { return false }
        if let prefix = activeConfiguredShortcutChordPrefixForCurrentEvent {
            guard let secondStroke = shortcut.secondStroke,
                  shortcut.firstStroke == prefix else {
                return false
            }
            return matchShortcutStroke(event: event, stroke: secondStroke)
        }
        guard !shortcut.hasChord else { return false }
        return matchShortcutStroke(event: event, stroke: shortcut.firstStroke)
    }

    func matchConfiguredShortcut(event: NSEvent, action: KeyboardShortcutSettings.Action) -> Bool {
        if !action.shortcutContext.isAlwaysAvailable && !action.shortcutContext.isAvailable(shortcutEventFocusContext(event)) { return false }
        return matchConfiguredShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: action))
    }

    func shouldForwardBrowserSurfaceShortcutToTerminal(_ event: NSEvent) -> Bool {
        return KeyboardShortcutSettings.Action.allCases.contains {
            $0.shortcutContext == .browserPanel &&
                !$0.isBrowserContentShortcut &&
                matchConfiguredShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: $0))
        }
    }

    func numberedConfiguredShortcutDigit(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action
    ) -> Int? {
        let shortcut = KeyboardShortcutSettings.shortcut(for: action)
        guard !shortcut.isUnbound else { return nil }
        if let prefix = activeConfiguredShortcutChordPrefixForCurrentEvent {
            guard let secondStroke = shortcut.secondStroke,
                  shortcut.firstStroke == prefix else {
                return nil
            }
            return numberedShortcutDigit(event: event, stroke: secondStroke)
        }
        guard !shortcut.isUnbound, !shortcut.hasChord else { return nil }
        return numberedShortcutDigit(event: event, stroke: shortcut.firstStroke)
    }

    func matchConfiguredDirectionalShortcut(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action,
        arrowGlyph: String,
        arrowKeyCode: UInt16
    ) -> Bool {
        let shortcut = KeyboardShortcutSettings.shortcut(for: action)
        guard !shortcut.isUnbound else { return false }
        if let prefix = activeConfiguredShortcutChordPrefixForCurrentEvent {
            guard let secondStroke = shortcut.secondStroke,
                  shortcut.firstStroke == prefix else {
                return false
            }
            return matchDirectionalShortcut(
                event: event,
                stroke: secondStroke,
                arrowGlyph: arrowGlyph,
                arrowKeyCode: arrowKeyCode
            )
        }
        guard !shortcut.hasChord else { return false }
        return matchDirectionalShortcut(
            event: event,
            stroke: shortcut.firstStroke,
            arrowGlyph: arrowGlyph,
            arrowKeyCode: arrowKeyCode
        )
    }

    func configuredShortcutChordWindowNumber(for event: NSEvent) -> Int? {
        if let window = mainWindowForShortcutEvent(event) {
            return window.windowNumber
        }
        if let window = event.window {
            return window.windowNumber
        }
        return event.windowNumber > 0 ? event.windowNumber : nil
    }

    func armConfiguredShortcutChordIfNeeded(
        event: NSEvent,
        actions: [KeyboardShortcutSettings.Action],
        shortcuts: [StoredShortcut] = []
    ) -> Bool {
        var seen = Set<StoredShortcut>()
        let configuredShortcuts = actions.map {
            KeyboardShortcutSettings.shortcut(for: $0)
        } + shortcuts
        for shortcut in configuredShortcuts {
            guard seen.insert(shortcut).inserted else { continue }
            guard shortcut.hasChord else { continue }
            if matchShortcutStroke(event: event, stroke: shortcut.firstStroke) {
                pendingConfiguredShortcutChord = PendingConfiguredShortcutChord(
                    firstStroke: shortcut.firstStroke,
                    windowNumber: configuredShortcutChordWindowNumber(for: event)
                )
                return true
            }
        }
        return false
    }

    func configuredCmuxShortcutActions(
        for context: MainWindowContext?
    ) -> [CmuxResolvedConfigAction] {
        context?.cmuxConfigStore?.shortcutActions() ?? []
    }

    func handleConfiguredCmuxShortcut(
        event: NSEvent,
        actions: [CmuxResolvedConfigAction],
        context: MainWindowContext?
    ) -> Bool {
        for action in actions {
            guard let shortcut = action.shortcut,
                  matchConfiguredShortcut(event: event, shortcut: shortcut) else {
                continue
            }
            return executeConfiguredCmuxActionShortcut(
                action,
                event: event,
                context: context
            )
        }
        return false
    }

}
