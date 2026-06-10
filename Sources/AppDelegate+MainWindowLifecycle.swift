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


// MARK: - Main window activation, close, and closed-window history
extension AppDelegate {
    func focusMainWindow(windowId: UUID) -> Bool {
        guard let window = windowForMainWindowId(windowId) else { return false }
        let didFocus = mainWindowVisibilityController.focus(window, reason: .focusMainWindow)
        if didFocus {
            publishCmuxWindowLifecycle(name: "window.focused", windowId: windowId, origin: "focus_request")
        }
        return didFocus
    }

    func closeMainWindow(windowId: UUID, recordHistory: Bool = true) -> Bool {
        guard let window = windowForMainWindowId(windowId) else { return false }
        if !recordHistory {
            closedWindowHistorySuppressedWindowIds.insert(windowId)
        }
        window.performClose(nil)
        return true
    }

    func discardMainWindowWithoutClosedHistory(windowId: UUID) {
        guard let window = windowForMainWindowId(windowId) else { return }
        closedWindowHistorySuppressedWindowIds.insert(windowId)
        window.close()
    }

    private func confirmCloseMainWindow(_ window: NSWindow) -> Bool {
#if DEBUG
        if let debugCloseMainWindowConfirmationHandler {
            return debugCloseMainWindowConfirmationHandler(window)
        }
#endif

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "dialog.closeWindow.title", defaultValue: "Close window?")
        alert.informativeText = String(
            localized: "dialog.closeWindow.message",
            defaultValue: "This will close the current window and all of its workspaces."
        )
        alert.addButton(withTitle: String(localized: "common.close", defaultValue: "Close"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))

        let alertWindow = alert.window
        if let closeButton = alert.buttons.first {
            alertWindow.defaultButtonCell = closeButton.cell as? NSButtonCell
            alertWindow.initialFirstResponder = closeButton
            DispatchQueue.main.async {
                _ = alertWindow.makeFirstResponder(closeButton)
            }
        }

        return alert.runModal() == .alertFirstButtonReturn
    }

    @discardableResult
    func closeWindowWithConfirmation(_ window: NSWindow) -> Bool {
        guard isMainTerminalWindow(window) else {
            window.performClose(nil)
            return true
        }
        guard confirmCloseMainWindow(window) else { return true }
        window.performClose(nil)
        return true
    }

    func orderedMainWindowSummaries(referenceWindowId: UUID?) -> [MainWindowSummary] {
        let summaries = listMainWindowSummaries()
        return summaries.sorted { lhs, rhs in
            let lhsIsReference = lhs.windowId == referenceWindowId
            let rhsIsReference = rhs.windowId == referenceWindowId
            if lhsIsReference != rhsIsReference { return lhsIsReference }
            if lhs.isKeyWindow != rhs.isKeyWindow { return lhs.isKeyWindow }
            if lhs.isVisible != rhs.isVisible { return lhs.isVisible }
            return lhs.windowId.uuidString < rhs.windowId.uuidString
        }
    }

    func windowLabelsById(orderedSummaries: [MainWindowSummary], referenceWindowId: UUID?) -> [UUID: String] {
        var labels: [UUID: String] = [:]
        for (index, summary) in orderedSummaries.enumerated() {
            if summary.windowId == referenceWindowId {
                labels[summary.windowId] = String(localized: "menu.currentWindow", defaultValue: "Current Window")
            } else {
                let number = index + 1
                labels[summary.windowId] = String(localized: "menu.windowNumber", defaultValue: "Window \(number)")
            }
        }
        return labels
    }

    func workspaceDisplayName(_ workspace: Workspace) -> String {
        let trimmed = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "workspace.displayName.fallback", defaultValue: "Workspace") : trimmed
    }

    func installMainWindowKeyObserver() {
        guard windowKeyObservers.isEmpty else { return }
        let center = NotificationCenter.default
        windowKeyObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleCmuxWindowBecameKey(note)
            }
        })
        windowKeyObservers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleCmuxWindowResignedKey(note)
            }
        })
    }

    func activateMainWindowContext(_ context: MainWindowContext?) {
        guard let context else {
            tabManager = nil
            sidebarState = nil
            sidebarSelectionState = nil
            fileExplorerState = nil
            TerminalController.shared.setActiveTabManager(nil)
            return
        }
        tabManager = context.tabManager
        sidebarState = context.sidebarState
        sidebarSelectionState = context.sidebarSelectionState
        fileExplorerState = context.fileExplorerState
        TerminalController.shared.setActiveTabManager(context.tabManager)
    }

    func setActiveMainWindow(_ window: NSWindow) {
        guard let context = contextForMainTerminalWindow(window) else { return }
#if DEBUG
        let beforeManagerToken = debugManagerToken(tabManager)
#endif
        activateMainWindowContext(context)
#if DEBUG
        cmuxDebugLog(
            "mainWindow.active window={\(debugWindowToken(window))} context={\(debugContextToken(context))} beforeMgr=\(beforeManagerToken) afterMgr=\(debugManagerToken(tabManager)) \(debugShortcutRouteSnapshot())"
        )
#endif
    }

    func handleMainTerminalWindowShouldClose() -> Bool {
        // XCTest has no UI for the warn-before-quit dialog and would either block
        // on runModal or have NSApp.terminate kill the test process.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
        guard !isTerminatingApp, mainWindowContexts.count <= 1 else { return true }
        _ = handleQuitShortcutWarning()
        return false
    }

    func unregisterMainWindow(_ window: NSWindow) {
        // Reset cascade point so the next new window appears near the closing
        // window's position, matching upstream Ghostty behavior.
        let frame = window.frame
        lastCascadePoint = NSPoint(x: frame.minX, y: frame.maxY)
        let closingContext = contextForMainTerminalWindow(window, reindex: false)

        if let closingContext {
            recordClosedWindowHistoryIfNeeded(for: closingContext)
        }

        // Keep geometry available as a fallback for the next window placement.
        if !isTerminatingApp {
            persistWindowGeometry(from: window)
        }

        guard let removed = unregisterMainWindowContext(for: window) else { return }
        publishCmuxWindowLifecycle(name: "window.closed", windowId: removed.windowId, origin: "appkit_close")
        commandPaletteVisibilityByWindowId.removeValue(forKey: removed.windowId)
        commandPalettePendingOpenByWindowId.removeValue(forKey: removed.windowId)
        commandPaletteRecentRequestAtByWindowId.removeValue(forKey: removed.windowId)
        commandPaletteEscapeSuppressionByWindowId.remove(removed.windowId)
        commandPaletteEscapeSuppressionStartedAtByWindowId.removeValue(forKey: removed.windowId)
        commandPaletteSelectionByWindowId.removeValue(forKey: removed.windowId)
        commandPaletteSnapshotByWindowId.removeValue(forKey: removed.windowId)

        // Avoid stale notifications that can no longer be opened once the owning window is gone.
        if let store = notificationStore {
            for tab in removed.tabManager.tabs {
                store.clearNotifications(forTabId: tab.id)
            }
        }

        if tabManager === removed.tabManager {
            // Repoint "active" pointers to any remaining main terminal window.
            let nextContext: MainWindowContext? = {
                if let keyWindow = NSApp.keyWindow,
                   let ctx = contextForMainTerminalWindow(keyWindow, reindex: false) {
                    return ctx
                }
                return mainWindowContexts.values.first
            }()

            activateMainWindowContext(nextContext)
        }

        // During app termination we already persisted a full snapshot (with scrollback)
        // in applicationShouldTerminate/applicationWillTerminate. Saving again here would
        // overwrite it as windows tear down one-by-one, dropping closed windows and replay.
        if Self.shouldPersistSnapshotOnWindowUnregister(isTerminatingApp: isTerminatingApp) {
            saveSessionSnapshotAfterLoadingProcessDetectedIndexes(includeScrollback: false, removeWhenEmpty: false)
        }
    }

    private func recordClosedWindowHistoryIfNeeded(for context: MainWindowContext) {
        let shouldSuppressClosedWindowHistory = closedWindowHistorySuppressedWindowIds.remove(context.windowId) != nil
        guard !shouldSuppressClosedWindowHistory,
              !isTerminatingApp,
              !isApplyingSessionRestore else {
            return
        }
        // Closing the last tab closes the window, recording undo history. Prefer the warm
        // cached agent index over a synchronous `RestorableAgentSessionIndex.load()` so the
        // close does not freeze the main thread; fall back to a fresh load only while the
        // cache has not loaded yet (see closedPanelHistoryEntry).
        let snapshot = sessionWindowSnapshot(
            for: context,
            includeScrollback: true,
            restorableAgentIndex: SharedLiveAgentIndex.shared.currentIndexSchedulingRefresh()
                ?? RestorableAgentSessionIndex.load()
        )
        guard !snapshot.tabManager.workspaces.isEmpty else {
            return
        }
        ClosedItemHistoryStore.shared.push(.window(ClosedWindowHistoryEntry(
            windowId: context.windowId,
            snapshot: snapshot,
            workspaceIds: context.tabManager.sessionSnapshotWorkspaceIds()
        )))
    }

#if DEBUG
    func suppressClosedWindowHistoryForTesting(windowId: UUID) {
        closedWindowHistorySuppressedWindowIds.insert(windowId)
    }

    func recordClosedWindowHistoryForTesting(windowId: UUID) {
        guard let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }) else { return }
        recordClosedWindowHistoryIfNeeded(for: context)
    }

    func isClosedWindowHistorySuppressedForTesting(windowId: UUID) -> Bool {
        closedWindowHistorySuppressedWindowIds.contains(windowId)
    }
#endif

    func isMainTerminalWindow(_ window: NSWindow) -> Bool {
        if mainWindowContexts[ObjectIdentifier(window)] != nil {
            return true
        }
        guard let raw = window.identifier?.rawValue else { return false }
        return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
    }

    func workspaceForMainActor(tabId: UUID) -> Workspace? {
        tabManagerFor(tabId: tabId)?.tabs.first(where: { $0.id == tabId })
    }

    /// Returns the `Workspace` that owns `tabId`, if any.
    @MainActor
    func workspaceFor(tabId: UUID) -> Workspace? {
        workspaceForMainActor(tabId: tabId)
    }

    func closeMainWindowContainingTabId(_ tabId: UUID, recordHistory: Bool = true) {
#if DEBUG
        closeMainWindowContainingTabIdObserverForTesting?(tabId, recordHistory)
#endif
        guard let context = contextContainingTabId(tabId) else { return }
        let expectedIdentifier = "cmux.main.\(context.windowId.uuidString)"
        let window: NSWindow? = context.window ?? NSApp.windows.first(where: { $0.identifier?.rawValue == expectedIdentifier })
        if !recordHistory {
            closedWindowHistorySuppressedWindowIds.insert(context.windowId)
        }
        guard let window else {
            if !recordHistory {
                closedWindowHistorySuppressedWindowIds.remove(context.windowId)
            }
            return
        }
        window.performClose(nil)
    }

    @discardableResult
    func handleMinimalModeTitlebarDoubleClickMouseDown(event: NSEvent) -> Bool {
        windowDecorationsController.handleMinimalModeTitlebarDoubleClickMouseDown(event: event)
    }

    @discardableResult
    func handleMinimalModeSidebarChromeMouseDown(window: NSWindow, event: NSEvent) -> Bool {
        windowDecorationsController.handleMinimalModeSidebarChromeMouseDown(window: window, event: event)
    }

}
