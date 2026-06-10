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


// MARK: - CLI bonsplit pane commands
extension TerminalController {
    func listPanes() -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var result = ""
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                result = "ERROR: No tab selected"
                return
            }

            let paneIds = tab.bonsplitController.allPaneIds
            let focusedPaneId = tab.bonsplitController.focusedPaneId

            let lines = paneIds.enumerated().map { index, paneId in
                let selected = paneId == focusedPaneId ? "*" : " "
                let tabCount = tab.bonsplitController.tabs(inPane: paneId).count
                return "\(selected) \(index): \(paneId) [\(tabCount) tabs]"
            }
            result = lines.isEmpty ? "No panes" : lines.joined(separator: "\n")
        }
        return result
    }

    func listPaneSurfaces(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var result = ""
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                result = "ERROR: No tab selected"
                return
            }

            // Parse --pane=<pane-id|index> argument (UUID preferred).
            var paneArg: String?
            for part in args.split(separator: " ") {
                if part.hasPrefix("--pane=") {
                    paneArg = String(part.dropFirst(7))
                    break
                }
            }

            let paneIds = tab.bonsplitController.allPaneIds
            var targetPaneId: PaneID? = tab.bonsplitController.focusedPaneId
            if let paneArg {
                if let uuid = UUID(uuidString: paneArg),
                   let paneId = paneIds.first(where: { $0.id == uuid }) {
                    targetPaneId = paneId
                } else if let index = Int(paneArg), index >= 0, index < paneIds.count {
                    targetPaneId = paneIds[index]
                } else {
                    result = "ERROR: Pane not found"
                    return
                }
            }

            guard let paneId = targetPaneId else {
                result = "ERROR: No pane to list tabs from"
                return
            }

            let tabs = tab.bonsplitController.tabs(inPane: paneId)
            let selectedTab = tab.bonsplitController.selectedTab(inPane: paneId)

            let lines = tabs.enumerated().map { index, bonsplitTab in
                let selected = bonsplitTab.id == selectedTab?.id ? "*" : " "
                let panelId = tab.panelIdFromSurfaceId(bonsplitTab.id)
                let panelIdStr = panelId?.uuidString ?? "unknown"
                return "\(selected) \(index): \(bonsplitTab.title) [panel:\(panelIdStr)]"
            }
            result = lines.isEmpty ? "No tabs in pane" : lines.joined(separator: "\n")
        }
        return result
    }

    func focusPane(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let paneArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paneArg.isEmpty else { return "ERROR: Usage: focus_pane <pane_id>" }

        var result = "ERROR: Pane not found"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            let paneIds = tab.bonsplitController.allPaneIds

            // Try UUID first, then fall back to index
            if let uuid = UUID(uuidString: paneArg),
               let paneId = paneIds.first(where: { $0.id == uuid }) {
                tab.bonsplitController.focusPane(paneId)
                result = "OK"
            } else if let index = Int(paneArg), index >= 0, index < paneIds.count {
                tab.bonsplitController.focusPane(paneIds[index])
                result = "OK"
            }
        }
        return result
    }

	    func focusSurfaceByPanel(_ args: String) -> String {
	        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let tabArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tabArg.isEmpty else { return "ERROR: Usage: focus_surface_by_panel <panel_id>" }

        var result = "ERROR: Panel not found"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            // Focus by panel UUID (our stable surface handle). This must also move AppKit
            // first responder into the terminal view to ensure typing routes correctly.
            if let panelUUID = UUID(uuidString: tabArg),
               tab.panels[panelUUID] != nil,
               tab.surfaceIdFromPanelId(panelUUID) != nil {
                tabManager.focusSurface(tabId: tab.id, surfaceId: panelUUID)
                result = "OK"
            }
        }
	        return result
	    }
	
	    func dragSurfaceToSplit(_ args: String) -> String {
	        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
	
	        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
	        let parts = trimmed.split(separator: " ").map(String.init)
	        guard parts.count >= 2 else { return "ERROR: Usage: drag_surface_to_split <id|idx> <left|right|up|down>" }
	
	        let surfaceArg = parts[0]
	        let directionArg = parts[1]
	        guard let direction = parseSplitDirection(directionArg) else {
	            return "ERROR: Invalid direction. Use left, right, up, or down."
	        }
	
	        let orientation: SplitOrientation = direction.isHorizontal ? .horizontal : .vertical
	        let insertFirst = (direction == .left || direction == .up)

	        v2MainSync { self.v2RefreshKnownRefs() }
	        if let stableSurfaceId = v2UUID(["surface_id": surfaceArg], "surface_id") {
	            switch v2SurfaceSplitOff(params: [
	                "surface_id": stableSurfaceId.uuidString,
	                "direction": directionArg,
	                "focus": false
	            ]) {
	            case .ok(let payload):
	                let dict = payload as? [String: Any]
	                let paneId = (dict?["pane_id"] as? String) ?? ""
	                return paneId.isEmpty ? "OK" : "OK \(paneId)"
	            case .err(_, let message, _):
	                return "ERROR: \(message)"
	            }
	        }
	
	        var result = "ERROR: Failed to move surface"
	        v2MainSync {
	            guard let tabId = tabManager.selectedTabId,
	                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
	                result = "ERROR: No tab selected"
	                return
	            }
	
	            guard let panelId = resolveSurfaceId(from: surfaceArg, tab: tab),
	                  let bonsplitTabId = tab.surfaceIdFromPanelId(panelId) else {
	                result = "ERROR: Surface not found"
	                return
	            }
	
	            guard let newPaneId = tab.bonsplitController.splitPane(
	                orientation: orientation,
	                movingTab: bonsplitTabId,
	                insertFirst: insertFirst
	            ) else {
	                result = "ERROR: Failed to split pane"
	                return
	            }
	
	            result = "OK \(newPaneId.id.uuidString)"
	        }
	        return result
	    }
	
    func newPane(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        // Parse arguments: --type=terminal|browser --direction=left|right|up|down --url=...
        var panelType: PanelType = .terminal
        var direction: SplitDirection = .right
        var urlRaw: String? = nil
        var url: URL? = nil
        var invalidDirection = false

        let parts = args.split(separator: " ")
        for part in parts {
            let partStr = String(part)
            if partStr.hasPrefix("--type=") {
                let typeStr = String(partStr.dropFirst(7))
                panelType = typeStr == "browser" ? .browser : .terminal
            } else if partStr.hasPrefix("--direction=") {
                let dirStr = String(partStr.dropFirst(12))
                if let parsed = parseSplitDirection(dirStr) {
                    direction = parsed
                } else {
                    invalidDirection = true
                }
            } else if partStr.hasPrefix("--url=") {
                let urlStr = String(partStr.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                urlRaw = urlStr.isEmpty ? nil : urlStr
                url = urlRaw.flatMap { URL(string: $0) }
            }
        }

        if invalidDirection {
            return "ERROR: Invalid direction. Use left, right, up, or down."
        }
        if panelType == .browser, BrowserAvailabilitySettings.isDisabled() {
            return openExternallyWhenBrowserDisabled(rawURL: urlRaw, url: url)
        }

        let orientation = direction.orientation
        let insertFirst = direction.insertFirst

        var result = "ERROR: Failed to create pane"
        let focus = socketCommandAllowsInAppFocusMutations()
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let focusedPanelId = tab.focusedPanelId else {
                return
            }

            let newPanelId: UUID?
            if panelType == .browser {
                newPanelId = tab.newBrowserSplit(
                    from: focusedPanelId,
                    orientation: orientation,
                    insertFirst: insertFirst,
                    url: url,
                    focus: focus,
                    creationPolicy: .automationPreload
                )?.id
            } else {
                newPanelId = tab.newTerminalSplit(
                    from: focusedPanelId,
                    orientation: orientation,
                    insertFirst: insertFirst,
                    focus: focus
                )?.id
            }

            if let id = newPanelId {
                result = "OK \(id.uuidString)"
            }
        }
        return result
    }

    // MARK: - Option Parsing (sidebar metadata commands)

}
