import AppKit
import Bonsplit
import CmuxControlSocket
import Foundation

/// The system-domain action witnesses (`workspace.action`, `surface.action` /
/// `tab.action`): the `workspace.action` bridge to the still-shared
/// `v2WorkspaceAction` (also driven by the mobile host's gated
/// `v2MobileWorkspaceAction` wrapper, so the body stays app-side) and the
/// byte-faithful mutation switch of the former `v2TabAction`. Split out of
/// `TerminalController+ControlSystemContext` to keep the conformance readable.
extension TerminalController {

    // MARK: - workspace.action (bridge to the still-shared v2WorkspaceAction)

    func controlWorkspaceAction(params: [String: JSONValue]) -> ControlCallResult {
        // `v2WorkspaceAction` stays in TerminalController.swift (shared with the
        // mobile host's gated `v2MobileWorkspaceAction`). Forward the raw params
        // and bridge its Foundation result, exactly as `surface.split_off` does.
        let foundationParams = params.mapValues(\.foundationObject)
        switch v2WorkspaceAction(params: foundationParams) {
        case let .ok(payload):
            return .ok(JSONValue(foundationObject: payload) ?? .object([:]))
        case let .err(code, message, data):
            return .err(code: code, message: message, data: data.flatMap { JSONValue(foundationObject: $0) })
        }
    }

    // MARK: - surface.action / tab.action

    func controlTabAction(
        routing: ControlRoutingSelectors,
        actionKey: String?,
        title: String?,
        rawURL: String?,
        surfaceID: UUID?,
        requestedFocus: Bool,
        moveParams: [String: JSONValue]
    ) -> ControlTabActionResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let action = actionKey else {
            return .missingAction
        }

        let resolvesMirroredTab = action == "rename"
        let workspace = resolvesMirroredTab
            ? resolveSurfaceWorkspace(routing: routing, tabManager: tabManager)
            : controlTabActionResolveWorkspace(routing: routing, tabManager: tabManager)
        guard let workspace else {
            return .workspaceNotFound
        }

        let resolvedSurfaceId: UUID?
        if let surfaceID {
            resolvedSurfaceId = surfaceID
        } else if resolvesMirroredTab,
                  let paneID = routing.paneID,
                  let location = workspace.remoteTmuxControlPane(paneID: paneID) {
            resolvedSurfaceId = location.pane.panel.id
        } else if resolvesMirroredTab {
            resolvedSurfaceId = workspace.focusedPanelId.flatMap {
                workspace.controlSurfaceProjection(forContainerPanelID: $0)?.surfaceID
            }
        } else {
            resolvedSurfaceId = workspace.focusedPanelId
        }
        guard let surfaceId = resolvedSurfaceId else {
            return .noFocusedTab
        }

        let panelId: UUID
        let outcomePaneId: UUID?
        if resolvesMirroredTab {
            guard let tabTarget = workspace.controlTabTarget(for: surfaceId) else {
                return .tabNotFound(surfaceID: surfaceId)
            }
            panelId = tabTarget.panelID
            outcomePaneId = tabTarget.paneID
        } else {
            guard workspace.panels[surfaceId] != nil else {
                return .tabNotFound(surfaceID: surfaceId)
            }
            panelId = surfaceId
            outcomePaneId = workspace.paneId(forPanelId: surfaceId)?.id
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        let focus = v2FocusAllowed(requested: requestedFocus)

        func finish(_ extras: ControlTabActionResolution.Extras) -> ControlTabActionResolution {
            .completed(ControlTabActionResolution.Outcome(
                workspaceID: workspace.id,
                surfaceID: surfaceId,
                windowID: windowId,
                paneID: outcomePaneId,
                extras: extras
            ))
        }

        func insertionIndexToRight(anchorTabId: TabID, inPane paneId: PaneID) -> Int {
            let tabs = workspace.bonsplitController.tabs(inPane: paneId)
            guard let anchorIndex = tabs.firstIndex(where: { $0.id == anchorTabId }) else { return tabs.count }
            let pinnedCount = tabs.reduce(into: 0) { count, tab in
                if let panelId = workspace.panelIdFromSurfaceId(tab.id),
                   workspace.isPanelPinned(panelId) {
                    count += 1
                }
            }
            let rawTarget = min(anchorIndex + 1, tabs.count)
            return max(rawTarget, pinnedCount)
        }

        func closeTabs(_ tabIds: [TabID]) -> (closed: Int, skippedPinned: Int) {
            var closed = 0
            var skippedPinned = 0
            for tabId in tabIds {
                guard let panelId = workspace.panelIdFromSurfaceId(tabId) else { continue }
                if workspace.isPanelPinned(panelId) {
                    skippedPinned += 1
                    continue
                }
                if workspace.panels.count <= 1 {
                    break
                }
                if workspace.requestNonInteractiveCloseTabRecordingHistory(tabId) {
                    closed += 1
                }
            }
            return (closed, skippedPinned)
        }

        switch action {
        case "rename":
            guard let titleRaw = title,
                  !titleRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .invalidTitle
            }
            let trimmedTitle = titleRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            workspace.setPanelCustomTitle(panelId: panelId, title: trimmedTitle)
            return finish(.title(trimmedTitle))

        case "clear_name":
            workspace.setPanelCustomTitle(panelId: panelId, title: nil)
            return finish(.none)

        case "pin":
            workspace.setPanelPinned(panelId: panelId, pinned: true)
            return finish(.pinned(true))

        case "unpin":
            workspace.setPanelPinned(panelId: panelId, pinned: false)
            return finish(.pinned(false))

        case "mark_read":
            workspace.markPanelRead(panelId)
            return finish(.none)

        case "mark_unread", "mark_as_unread":
            workspace.markPanelUnread(panelId)
            return finish(.none)

        case "toggle_full_width_tab", "toggle_full_width", "toggle_full_width_tab_mode":
            guard let paneId = workspace.paneId(forPanelId: panelId) else {
                return .tabPaneNotFound
            }
            guard workspace.toggleFullWidthTabMode(panelId: panelId) else {
                return .fullWidthTabToggleFailed
            }
            return finish(.fullWidthTabMode(workspace.bonsplitController.isFullWidthTabMode(inPane: paneId)))

        case "move_to_new_workspace", "detach_to_workspace", "detach_to_new_workspace":
            // The move-to-new-workspace family stays app-side (it re-homes
            // surfaces across TabManagers); bridge its fully-shaped result.
            let foundationParams = moveParams.mapValues(\.foundationObject)
            switch v2MoveTabToNewWorkspaceActionResult(
                action: action,
                params: foundationParams,
                tabManager: tabManager,
                workspace: workspace,
                surfaceId: panelId
            ) {
            case let .ok(payload):
                return .bridged(.ok(JSONValue(foundationObject: payload) ?? .object([:])))
            case let .err(code, message, data):
                return .bridged(.err(
                    code: code,
                    message: message,
                    data: data.flatMap { JSONValue(foundationObject: $0) }
                ))
            }

        case "reload", "reload_tab":
            guard let browserPanel = workspace.browserPanel(for: panelId) else {
                return .reloadNotBrowser
            }
            browserPanel.reload()
            return finish(.none)

        case "duplicate", "duplicate_tab":
            guard let browserPanel = workspace.browserPanel(for: panelId) else {
                return .duplicateNotBrowser
            }
            guard BrowserAvailabilitySettings.isEnabled() else {
                return .browserDisabled(tabActionBrowserDisabledOutcome(
                    rawURL: nil,
                    url: browserPanel.currentURLForTabDuplication,
                    tabManager: tabManager
                ))
            }

            guard let newPanel = workspace.duplicateBrowserToRight(panelId: panelId, focus: focus) else {
                return .duplicateFailed
            }
            return finish(.created(newPanel.id))

        case "new_terminal_right", "new_terminal_to_right", "new_terminal_tab_to_right":
            guard let anchorTabId = workspace.surfaceIdFromPanelId(panelId),
                  let paneId = workspace.paneId(forPanelId: panelId) else {
                return .tabPaneNotFound
            }

            let targetIndex = insertionIndexToRight(anchorTabId: anchorTabId, inPane: paneId)
            switch workspace.newTerminalSurfaceOutcome(
                inPane: paneId,
                focus: focus,
                inheritWorkingDirectoryFallback: true,
                workingDirectoryFallbackSourcePanelId: panelId,
                allowTextBoxFocusDefault: false
            ) {
            case .created(let newPanel):
                _ = workspace.reorderSurface(panelId: newPanel.id, toIndex: targetIndex, focus: focus)
                return finish(.created(newPanel.id))
            case .routedToRemote:
                // Routed to the remote tmux mirror as `new-window`; the tab arrives
                // via %window-add and the mirror positions it, so no local reorder here.
                return finish(.routedToRemote)
            case .failed:
                return .createFailed
            }

        case "new_browser_right", "new_browser_to_right", "new_browser_tab_to_right":
            guard let anchorTabId = workspace.surfaceIdFromPanelId(panelId),
                  let paneId = workspace.paneId(forPanelId: panelId) else {
                return .tabPaneNotFound
            }

            let url = rawURL.flatMap { URL(string: $0) }
            if let rawURL, url == nil {
                return .invalidURL(rawURL: rawURL)
            }
            guard BrowserAvailabilitySettings.isEnabled() else {
                return .browserDisabled(tabActionBrowserDisabledOutcome(
                    rawURL: rawURL,
                    url: url,
                    tabManager: tabManager
                ))
            }

            let targetIndex = insertionIndexToRight(anchorTabId: anchorTabId, inPane: paneId)
            guard let newPanel = workspace.newBrowserSurface(
                inPane: paneId,
                url: url,
                focus: focus,
                creationPolicy: .automationPreload
            ) else {
                return .createFailed
            }
            _ = workspace.reorderSurface(panelId: newPanel.id, toIndex: targetIndex, focus: focus)
            return finish(.created(newPanel.id))

        case "close_left", "close_to_left":
            guard let anchorTabId = workspace.surfaceIdFromPanelId(panelId),
                  let paneId = workspace.paneId(forPanelId: panelId) else {
                return .tabPaneNotFound
            }
            let tabs = workspace.bonsplitController.tabs(inPane: paneId)
            guard let index = tabs.firstIndex(where: { $0.id == anchorTabId }) else {
                return .tabNotFoundInPane
            }
            let targetIds = Array(tabs.prefix(index).map(\.id))
            let closeResult = closeTabs(targetIds)
            return finish(.closed(closed: closeResult.closed, skippedPinned: closeResult.skippedPinned))

        case "close_right", "close_to_right":
            guard let anchorTabId = workspace.surfaceIdFromPanelId(panelId),
                  let paneId = workspace.paneId(forPanelId: panelId) else {
                return .tabPaneNotFound
            }
            let tabs = workspace.bonsplitController.tabs(inPane: paneId)
            guard let index = tabs.firstIndex(where: { $0.id == anchorTabId }) else {
                return .tabNotFoundInPane
            }
            let targetIds = (index + 1 < tabs.count) ? Array(tabs.suffix(from: index + 1).map(\.id)) : []
            let closeResult = closeTabs(targetIds)
            return finish(.closed(closed: closeResult.closed, skippedPinned: closeResult.skippedPinned))

        case "close_others", "close_other_tabs":
            guard let anchorTabId = workspace.surfaceIdFromPanelId(panelId),
                  let paneId = workspace.paneId(forPanelId: panelId) else {
                return .tabPaneNotFound
            }
            let targetIds = workspace.bonsplitController.tabs(inPane: paneId)
                .map(\.id)
                .filter { $0 != anchorTabId }
            let closeResult = closeTabs(targetIds)
            return finish(.closed(closed: closeResult.closed, skippedPinned: closeResult.skippedPinned))

        default:
            return .unknownAction
        }
    }

    /// Preserves the legacy workspace resolver for non-rename tab actions.
    /// Remote tmux projections are window-tab aliases only for rename;
    /// unrelated actions retain their existing workspace-panel semantics.
    private func controlTabActionResolveWorkspace(
        routing: ControlRoutingSelectors,
        tabManager: TabManager
    ) -> Workspace? {
        if let wsId = routing.workspaceID {
            return tabManager.tabs.first(where: { $0.id == wsId })
        }
        if let surfaceId = routing.surfaceID {
            return tabManager.tabs.first(where: { $0.panels[surfaceId] != nil })
        }
        if let paneId = routing.paneID, let located = v2LocatePane(paneId) {
            guard located.tabManager === tabManager else { return nil }
            return located.workspace
        }
        guard let wsId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == wsId })
    }

    /// The byte-faithful twin of `v2BrowserDisabledExternalOpenResult`, mapped
    /// onto the shared ``ControlSurfaceBrowserDisabledOutcome``.
    private func tabActionBrowserDisabledOutcome(
        rawURL: String?,
        url: URL?,
        tabManager: TabManager?
    ) -> ControlSurfaceBrowserDisabledOutcome {
        if let rawURL, url == nil {
            return .invalidURL(rawURL: rawURL)
        }
        guard let url else {
            return .noURL
        }
        guard NSWorkspace.shared.open(url) else {
            return .externalOpenFailed(url: url.absoluteString)
        }
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .openedExternally(windowID: windowId, url: url.absoluteString)
    }
}
