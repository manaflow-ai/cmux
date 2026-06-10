import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSocketControl
import CmuxSwiftRenderUI
import Carbon.HIToolbox
import CMUXMobileCore
import CMUXWorkstream
import Foundation
import Bonsplit
import WebKit


// MARK: - CLI window, workspace, and surface commands
extension TerminalController {
    func listWindows() -> String {
        let summaries = v2MainSync { AppDelegate.shared?.listMainWindowSummaries() } ?? []
        guard !summaries.isEmpty else { return "No windows" }

        let lines = summaries.enumerated().map { idx, item in
            let selected = item.isKeyWindow ? "*" : " "
            let selectedWs = item.selectedWorkspaceId?.uuidString ?? "none"
            return "\(selected) \(idx): \(item.windowId.uuidString) selected_workspace=\(selectedWs) workspaces=\(item.workspaceCount)"
        }
        return lines.joined(separator: "\n")
    }

    func currentWindow() -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }
        guard let windowId = v2ResolveWindowId(tabManager: tabManager) else { return "ERROR: No active window" }
        return windowId.uuidString
    }

    func focusWindow(_ arg: String) -> String {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let windowId = UUID(uuidString: trimmed) else { return "ERROR: Invalid window id" }

        let ok = v2MainSync { AppDelegate.shared?.focusMainWindow(windowId: windowId) ?? false }
        guard ok else { return "ERROR: Window not found" }

        if let tm = v2MainSync({ AppDelegate.shared?.tabManagerFor(windowId: windowId) }) {
            setActiveTabManager(tm)
        }
        return "OK"
    }

    func newWindow() -> String {
        guard let windowId = v2MainSync({ AppDelegate.shared?.createMainWindow() }) else {
            return "ERROR: Failed to create window"
        }
        if let tm = v2MainSync({ AppDelegate.shared?.tabManagerFor(windowId: windowId) }) {
            setActiveTabManager(tm)
        }
        return "OK \(windowId.uuidString)"
    }

    func closeWindow(_ arg: String) -> String {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let windowId = UUID(uuidString: trimmed) else { return "ERROR: Invalid window id" }
        let ok = v2MainSync { AppDelegate.shared?.closeMainWindow(windowId: windowId) ?? false }
        return ok ? "OK" : "ERROR: Window not found"
    }

    func moveWorkspaceToWindow(_ args: String) -> String {
        let parts = args.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return "ERROR: Usage move_workspace_to_window <workspace_id> <window_id>" }
        guard let wsId = UUID(uuidString: parts[0]) else { return "ERROR: Invalid workspace id" }
        guard let windowId = UUID(uuidString: parts[1]) else { return "ERROR: Invalid window id" }

        var ok = false
        let focus = socketCommandAllowsInAppFocusMutations()
        v2MainSync {
            guard let srcTM = AppDelegate.shared?.tabManagerFor(tabId: wsId),
                  let dstTM = AppDelegate.shared?.tabManagerFor(windowId: windowId),
                  let ws = srcTM.detachWorkspace(tabId: wsId) else {
                ok = false
                return
            }
            dstTM.attachWorkspace(ws, select: focus)
            if focus {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(dstTM)
            }
            ok = true
        }

        return ok ? "OK" : "ERROR: Move failed"
    }

    func listWorkspaces() -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var result: String = ""
        v2MainSync {
            let tabs = tabManager.tabs.enumerated().map { (index, tab) in
                let selected = tab.id == tabManager.selectedTabId ? "*" : " "
                return "\(selected) \(index): \(tab.id.uuidString) \(tab.title)"
            }
            result = tabs.joined(separator: "\n")
        }
        return result.isEmpty ? "No workspaces" : result
    }

    func newWorkspace(_ args: String = "") -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String? = trimmed.isEmpty ? nil : trimmed

        var newTabId: UUID?
        let focus = socketCommandAllowsInAppFocusMutations()
        v2MainSync {
            let workspace = tabManager.addWorkspace(title: title, select: focus, eagerLoadTerminal: !focus)
            newTabId = workspace.id
        }
        return "OK \(newTabId?.uuidString ?? "unknown")"
    }

    func newSplit(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard !parts.isEmpty else {
            return "ERROR: Invalid direction. Use left, right, up, or down."
        }

        let directionArg = parts[0]
        let panelArg = parts.count > 1 ? parts[1] : ""

        guard let direction = parseSplitDirection(directionArg) else {
            return "ERROR: Invalid direction. Use left, right, up, or down."
        }

        var result = "ERROR: Failed to create split"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            // If panel arg provided, resolve it; otherwise use focused panel
            let surfaceId: UUID?
            if !panelArg.isEmpty {
                surfaceId = resolveSurfaceId(from: panelArg, tab: tab)
                if surfaceId == nil {
                    result = "ERROR: Panel not found"
                    return
                }
            } else {
                surfaceId = tab.focusedPanelId
            }

            guard let targetSurface = surfaceId else {
                result = "ERROR: No surface to split"
                return
            }

            if let newPanelId = tabManager.newSplit(tabId: tabId, surfaceId: targetSurface, direction: direction) {
                result = "OK \(newPanelId.uuidString)"
            }
        }
        return result
    }

    func listSurfaces(_ tabArg: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        var result = ""
        v2MainSync {
            guard let tab = resolveTab(from: tabArg, tabManager: tabManager) else {
                result = "ERROR: Tab not found"
                return
            }
            let panels = orderedPanels(in: tab)
            let focusedId = tab.focusedPanelId
            let lines = panels.enumerated().map { index, panel in
                let selected = panel.id == focusedId ? "*" : " "
                return "\(selected) \(index): \(panel.id.uuidString)"
            }
            result = lines.isEmpty ? "No surfaces" : lines.joined(separator: "\n")
        }
        return result
    }

    func focusSurface(_ arg: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Missing panel id or index" }

        var success = false
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            if let uuid = UUID(uuidString: trimmed),
               tab.panels[uuid] != nil {
                guard tab.surfaceIdFromPanelId(uuid) != nil else { return }
                tabManager.focusSurface(tabId: tab.id, surfaceId: uuid)
                success = true
                return
            }

            if let index = Int(trimmed), index >= 0 {
                let panels = orderedPanels(in: tab)
                guard index < panels.count else { return }
                guard tab.surfaceIdFromPanelId(panels[index].id) != nil else { return }
                tabManager.focusSurface(tabId: tab.id, surfaceId: panels[index].id)
                success = true
            }
        }

        return success ? "OK" : "ERROR: Panel not found"
    }

    func parseSplitDirection(_ value: String) -> SplitDirection? {
        switch value.lowercased() {
        case "left", "l":
            return .left
        case "right", "r":
            return .right
        case "up", "u":
            return .up
        case "down", "d":
            return .down
        default:
            return nil
        }
    }

    func resolveTab(from arg: String, tabManager: TabManager) -> Tab? {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard let selected = tabManager.selectedTabId else { return nil }
            return tabManager.tabs.first(where: { $0.id == selected })
        }

        if let uuid = UUID(uuidString: trimmed) {
            return tabManager.tabs.first(where: { $0.id == uuid })
        }

        if let index = Int(trimmed), index >= 0, index < tabManager.tabs.count {
            return tabManager.tabs[index]
        }

        return nil
    }

    func orderedPanels(in tab: Workspace) -> [any Panel] {
        // Single source of truth for spatial (left-to-right, top-to-bottom) panel
        // order lives on `Workspace.orderedPanelIds`, derived from bonsplit's tab
        // ordering. This avoids relying on Dictionary iteration order and keeps the
        // serializer, the reorder gate, and the mobile observer hash consistent.
        tab.orderedPanelIds.compactMap { tab.panels[$0] }
    }

    func resolveTerminalPanel(from arg: String, tabManager: TabManager) -> TerminalPanel? {
        guard let tabId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
            return nil
        }

        if let uuid = UUID(uuidString: arg) {
            return tab.terminalPanel(for: uuid)
        }

        if let index = Int(arg), index >= 0 {
            let panels = orderedPanels(in: tab)
            guard index < panels.count else { return nil }
            return panels[index] as? TerminalPanel
        }

        return nil
    }

    func resolveSurfaceId(from arg: String, tab: Workspace) -> UUID? {
        if let uuid = UUID(uuidString: arg), tab.panels[uuid] != nil {
            return uuid
        }

        if let index = Int(arg), index >= 0 {
            let panels = orderedPanels(in: tab)
            guard index < panels.count else { return nil }
            return panels[index].id
        }

        return nil
    }

    func parseNotificationPayload(_ args: String) -> (String, String, String) {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("Notification", "", "") }
        let parts = trimmed.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        let title = parts.count > 0 ? parts[0].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let subtitle = parts.count > 2 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let body = parts.count > 2
            ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
            : (parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "")
        return (title.isEmpty ? "Notification" : title, subtitle, body)
    }

    func closeWorkspace(_ tabId: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        guard let uuid = UUID(uuidString: tabId) else { return "ERROR: Invalid tab ID" }

        var result = "ERROR: Tab not found"
        v2MainSync {
            if let tab = tabManager.tabs.first(where: { $0.id == uuid }) {
                guard tabManager.canCloseWorkspace(tab) else {
                    result = "ERROR: \(workspaceCloseProtectedMessage())"
                    return
                }
                tabManager.closeTab(tab)
                result = "OK"
            }
        }
        return result
    }

    func selectWorkspace(_ arg: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var success = false
        v2MainSync {
            // Try as UUID first
            if let uuid = UUID(uuidString: arg) {
                if let tab = tabManager.tabs.first(where: { $0.id == uuid }) {
                    tabManager.selectTab(tab)
                    success = true
                }
            }
            // Try as index
            else if let index = Int(arg), index >= 0, index < tabManager.tabs.count {
                tabManager.selectTab(at: index)
                success = true
            }
        }
        return success ? "OK" : "ERROR: Tab not found"
    }

    func currentWorkspace() -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var result: String = ""
        v2MainSync {
            if let id = tabManager.selectedTabId {
                result = id.uuidString
            }
        }
        return result.isEmpty ? "ERROR: No tab selected" : result
    }

    func reloadConfig(_ args: String) -> String {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.isEmpty else {
            return "ERROR: Usage: reload_config"
        }

        v2MainSync {
            if let appDelegate = AppDelegate.shared {
                appDelegate.reloadConfiguration(source: "socket.reload_config")
            } else {
                GhosttyApp.shared.reloadConfiguration(source: "socket.reload_config")
            }
        }
        return "OK Reloaded config"
    }

    func refreshSurfaces() -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var refreshedCount = 0
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            // Force-refresh all terminal panels in current tab
            // (resets cached metrics so the Metal layer drawable resizes correctly)
            for panel in tab.panels.values {
                if let terminalPanel = panel as? TerminalPanel {
                    terminalPanel.surface.forceRefresh(reason: "terminalController.refreshAllTerminalPanels")
                    refreshedCount += 1
                }
            }
        }
        return "OK Refreshed \(refreshedCount) surfaces"
    }

    private func viewDepth(of view: NSView, maxDepth: Int = 128) -> Int {
        var depth = 0
        var current: NSView? = view
        while let v = current, depth < maxDepth {
            current = v.superview
            depth += 1
        }
        return depth
    }

    private func isPortalHosted(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let v = current {
            if v is WindowTerminalHostView { return true }
            current = v.superview
        }
        return false
    }

    func surfaceHealth(_ tabArg: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        var result = ""
        v2MainSync {
            guard let tab = resolveTab(from: tabArg, tabManager: tabManager) else {
                result = "ERROR: Tab not found"
                return
            }
            let panels = orderedPanels(in: tab)
            let lines = panels.enumerated().map { index, panel -> String in
                let panelId = panel.id.uuidString
                let type = panel.panelType.rawValue
                if let tp = panel as? TerminalPanel {
                    let inWindow = tp.surface.isViewInWindow
                    let portalHosted = isPortalHosted(tp.hostedView)
                    let depth = viewDepth(of: tp.hostedView)
                    return "\(index): \(panelId) type=\(type) in_window=\(inWindow) portal=\(portalHosted) view_depth=\(depth)"
                } else if let bp = panel as? BrowserPanel {
                    let inWindow = bp.webView.window != nil
                    return "\(index): \(panelId) type=\(type) in_window=\(inWindow)"
                } else {
                    return "\(index): \(panelId) type=\(type) in_window=unknown"
                }
            }
            result = lines.isEmpty ? "No surfaces" : lines.joined(separator: "\n")
        }
        return result
    }

    func closeSurface(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)

        var result = "ERROR: Failed to close surface"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            // Resolve surface ID from argument or use focused
            let surfaceId: UUID?
            if trimmed.isEmpty {
                surfaceId = tab.focusedPanelId
            } else {
                surfaceId = resolveSurfaceId(from: trimmed, tab: tab)
            }

            guard let targetSurfaceId = surfaceId else {
                result = "ERROR: Surface not found"
                return
            }

            // Don't close if it's the only surface
            if tab.panels.count <= 1 {
                result = "ERROR: Cannot close the last surface"
                return
            }

            // Socket commands must be non-interactive: bypass close-confirmation gating.
            result = closeSurfaceRecordingHistory(in: tab, surfaceId: targetSurfaceId, force: true)
                ? "OK"
                : "ERROR: Failed to close surface"
        }
        return result
    }

    func newSurface(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        // Parse arguments: --type=terminal|browser --pane=<pane_id> --url=...
        var panelType: PanelType = .terminal
        var paneArg: String? = nil
        var urlRaw: String? = nil
        var url: URL? = nil

        let parts = args.split(separator: " ")
        for part in parts {
            let partStr = String(part)
            if partStr.hasPrefix("--type=") {
                let typeStr = String(partStr.dropFirst(7))
                panelType = typeStr == "browser" ? .browser : .terminal
            } else if partStr.hasPrefix("--pane=") {
                paneArg = String(partStr.dropFirst(7))
            } else if partStr.hasPrefix("--url=") {
                let urlStr = String(partStr.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                urlRaw = urlStr.isEmpty ? nil : urlStr
                url = urlRaw.flatMap { URL(string: $0) }
            }
        }
        if panelType == .browser, BrowserAvailabilitySettings.isDisabled() {
            return openExternallyWhenBrowserDisabled(rawURL: urlRaw, url: url)
        }

        var result = "ERROR: Failed to create tab"
        let focus = socketCommandAllowsInAppFocusMutations()
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            // Get target pane
            let paneId: PaneID?
            let paneIds = tab.bonsplitController.allPaneIds
            if let paneArg {
                if let uuid = UUID(uuidString: paneArg) {
                    paneId = paneIds.first(where: { $0.id == uuid })
                } else if let idx = Int(paneArg), idx >= 0, idx < paneIds.count {
                    paneId = paneIds[idx]
                } else {
                    paneId = nil
                }
            } else {
                paneId = tab.bonsplitController.focusedPaneId
            }

            guard let targetPaneId = paneId else {
                result = "ERROR: Pane not found"
                return
            }

            let newPanelId: UUID?
            if panelType == .browser {
                newPanelId = tab.newBrowserSurface(
                    inPane: targetPaneId,
                    url: url,
                    focus: focus,
                    creationPolicy: .automationPreload
                )?.id
            } else {
                newPanelId = tab.newTerminalSurface(inPane: targetPaneId, focus: focus)?.id
            }

            if let id = newPanelId {
                result = "OK \(id.uuidString)"
            }
        }
        return result
    }

    // MARK: - Mobile Host V2 Methods

}
