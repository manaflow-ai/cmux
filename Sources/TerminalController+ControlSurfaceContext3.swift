import AppKit
import Bonsplit
import CmuxControlSocket
import CmuxFoundation
import CmuxTerminal
import Foundation
import GhosttyKit

/// The surface-domain input / read / resume / reporting witnesses, plus the
/// `surface.move` bridge and `debug.terminals` passthrough. Split out of
/// `TerminalController+ControlSurfaceContext` to keep the conformance readable; see
/// that file's doc comment for the overview.
extension TerminalController {

    // MARK: - move

    /// The former `v2SurfaceMove` `app.locateSurface` / `sourceWorkspace` reads,
    /// preserving the `AppDelegate`-unavailable vs surface-not-found split. The
    /// coordinator owns the routing precedence and branch; these witnesses keep
    /// every live window/workspace/pane lookup and Bonsplit mutation app-side.
    func controlSurfaceMoveLocateSource(surfaceID: UUID) -> ControlSurfaceMoveSourceResolution {
        guard let windowRegistry = appEnvironment?.windowRegistry else { return .appUnavailable }
        guard let source = windowRegistry.locateSurface(surfaceId: surfaceID),
              let sourceWorkspace = source.tabManager.tabs.first(where: { $0.id == source.workspaceId }) else {
            return .surfaceNotFound
        }
        let sourcePane = sourceWorkspace.paneId(forPanelId: surfaceID)
        let sourceIndex = sourceWorkspace.indexInPane(forPanelId: surfaceID)
        let defaultDestinationPane = sourcePane
            ?? sourceWorkspace.bonsplitController.focusedPaneId
            ?? sourceWorkspace.bonsplitController.allPaneIds.first
        return .located(ControlSurfaceMoveSourceSnapshot(
            windowID: source.windowId,
            workspaceID: sourceWorkspace.id,
            paneID: sourcePane?.id,
            index: sourceIndex,
            defaultDestinationPaneID: defaultDestinationPane?.id
        ))
    }

    func controlSurfaceMoveLocateAnchor(surfaceID: UUID) -> ControlSurfaceMoveAnchorSnapshot? {
        guard let anchor = appEnvironment?.windowRegistry.locateSurface(surfaceId: surfaceID),
              let anchorWorkspace = anchor.tabManager.tabs.first(where: { $0.id == anchor.workspaceId }),
              let anchorPane = anchorWorkspace.paneId(forPanelId: surfaceID),
              let anchorIndex = anchorWorkspace.indexInPane(forPanelId: surfaceID) else {
            return nil
        }
        return ControlSurfaceMoveAnchorSnapshot(
            windowID: anchor.windowId,
            workspaceID: anchorWorkspace.id,
            paneID: anchorPane.id,
            index: anchorIndex
        )
    }

    func controlSurfaceMoveLocatePane(paneID: UUID) -> ControlSurfaceMovePaneSnapshot? {
        guard let located = v2LocatePane(paneID) else { return nil }
        return ControlSurfaceMovePaneSnapshot(
            windowID: located.windowId,
            workspaceID: located.workspace.id,
            paneID: located.paneId.id
        )
    }

    func controlSurfaceMoveLocateWorkspace(workspaceID: UUID) -> ControlSurfaceMoveWorkspaceSnapshot? {
        guard let tabManager = appEnvironment?.windowRegistry.tabManagerFor(tabId: workspaceID),
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
            return nil
        }
        let destinationPane = workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first
        return ControlSurfaceMoveWorkspaceSnapshot(
            windowID: appEnvironment?.windowRegistry.windowId(for: tabManager),
            workspaceID: workspace.id,
            destinationPaneID: destinationPane?.id
        )
    }

    func controlSurfaceMoveLocateWindow(windowID: UUID) -> ControlSurfaceMoveWindowResolution {
        guard let tabManager = appEnvironment?.windowRegistry.tabManagerFor(windowId: windowID) else {
            return .windowNotFound
        }
        guard let selectedWorkspaceId = tabManager.selectedTabId,
              let workspace = tabManager.tabs.first(where: { $0.id == selectedWorkspaceId }) else {
            return .noSelectedWorkspace
        }
        let destinationPane = workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first
        return .resolved(workspaceID: workspace.id, destinationPaneID: destinationPane?.id)
    }

    func controlSurfaceMovePerformMove(
        workspaceID: UUID,
        surfaceID: UUID,
        destinationPaneID: UUID,
        index: Int?,
        requestedFocus: Bool
    ) -> Bool {
        let focus = v2FocusAllowed(requested: requestedFocus)
        guard let tabManager = appEnvironment?.windowRegistry.tabManagerFor(tabId: workspaceID),
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }),
              let destinationPane = workspace.bonsplitController.allPaneIds.first(where: { $0.id == destinationPaneID }) else {
            return false
        }
        return workspace.moveSurface(panelId: surfaceID, toPane: destinationPane, atIndex: index, focus: focus)
    }

    func controlSurfaceMovePerformTransfer(
        sourceWorkspaceID: UUID,
        sourcePaneID: UUID?,
        sourceIndex: Int?,
        targetWorkspaceID: UUID,
        targetWindowID: UUID,
        surfaceID: UUID,
        destinationPaneID: UUID,
        index: Int?,
        requestedFocus: Bool
    ) -> ControlSurfaceMoveTransferOutcome {
        let focus = v2FocusAllowed(requested: requestedFocus)
        guard let windowRegistry = appEnvironment?.windowRegistry,
              let sourceTabManager = windowRegistry.tabManagerFor(tabId: sourceWorkspaceID),
              let sourceWorkspace = sourceTabManager.tabs.first(where: { $0.id == sourceWorkspaceID }),
              let targetTabManager = windowRegistry.tabManagerFor(tabId: targetWorkspaceID),
              let targetWorkspace = targetTabManager.tabs.first(where: { $0.id == targetWorkspaceID }),
              let destinationPane = targetWorkspace.bonsplitController.allPaneIds.first(where: { $0.id == destinationPaneID }) else {
            return .detachFailed
        }

        guard let transfer = sourceWorkspace.detachSurface(panelId: surfaceID) else {
            return .detachFailed
        }

        if targetWorkspace.attachDetachedSurface(transfer, inPane: destinationPane, atIndex: index, focus: focus) == nil {
            // Roll back to source workspace if attach fails.
            let rollbackPane = sourcePaneID.flatMap { paneID in
                sourceWorkspace.bonsplitController.allPaneIds.first(where: { $0.id == paneID })
            }
                ?? sourceWorkspace.bonsplitController.focusedPaneId
                ?? sourceWorkspace.bonsplitController.allPaneIds.first
            if let rollbackPane {
                _ = sourceWorkspace.attachDetachedSurface(transfer, inPane: rollbackPane, atIndex: sourceIndex, focus: focus)
            }
            return .attachFailed
        }

        if focus {
            _ = appEnvironment?.mainWindowRouter.focusMainWindow(windowId: targetWindowID)
            setActiveTabManager(targetTabManager)
            targetTabManager.selectWorkspace(targetWorkspace)
        }

        return .transferred
    }

    // MARK: - reorder

    func controlSurfaceReorder(
        surfaceID: UUID,
        inputs: ControlSurfaceReorderInputs,
        requestedFocus: Bool
    ) -> ControlSurfaceReorderResolution {
        let focus = v2FocusAllowed(requested: requestedFocus)
        guard let located = appEnvironment?.windowRegistry.locateSurface(surfaceId: surfaceID),
              let ws = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
              let sourcePane = ws.paneId(forPanelId: surfaceID) else {
            return .surfaceNotFound(surfaceID)
        }

        let targetIndex: Int
        if let index = inputs.index {
            targetIndex = index
        } else if let beforeSurfaceID = inputs.beforeSurfaceID {
            guard let anchorPane = ws.paneId(forPanelId: beforeSurfaceID),
                  anchorPane == sourcePane,
                  let anchorIndex = ws.indexInPane(forPanelId: beforeSurfaceID) else {
                return .anchorNotInSamePane
            }
            targetIndex = anchorIndex
        } else if let afterSurfaceID = inputs.afterSurfaceID {
            guard let anchorPane = ws.paneId(forPanelId: afterSurfaceID),
                  anchorPane == sourcePane,
                  let anchorIndex = ws.indexInPane(forPanelId: afterSurfaceID) else {
                return .anchorNotInSamePane
            }
            targetIndex = anchorIndex + 1
        } else {
            // Unreachable: the coordinator enforces exactly-one-target.
            return .reorderFailed
        }

        guard ws.reorderSurface(panelId: surfaceID, toIndex: targetIndex, focus: focus) else {
            return .reorderFailed
        }
        return .reordered(
            windowID: located.windowId,
            workspaceID: ws.id,
            paneID: sourcePane.id,
            surfaceID: surfaceID
        )
    }

    // MARK: - refresh

    func controlSurfaceRefresh(routing: ControlRoutingSelectors) -> ControlSurfaceRefreshResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        if let dock = windowDockForRouting(routing, tabManager: tabManager) {
            var refreshedCount = 0
            for panel in dock.panels.values {
                if let terminalPanel = panel as? TerminalPanel {
                    terminalPanel.surface.forceRefresh(reason: "terminalController.v2SurfaceRefresh.windowDock")
                    refreshedCount += 1
                }
            }
            return .refreshed(
                windowID: dockResultWindowId(for: dock, tabManager: tabManager),
                workspaceID: dock.workspaceId,
                refreshedCount: refreshedCount
            )
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        var refreshedCount = 0
        for panel in ws.panels.values {
            if let terminalPanel = panel as? TerminalPanel {
                terminalPanel.surface.forceRefresh(reason: "terminalController.v2SurfaceRefresh")
                refreshedCount += 1
            }
        }
        return .refreshed(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            refreshedCount: refreshedCount
        )
    }

    // MARK: - clear_history

    func controlSurfaceClearHistory(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool
    ) -> ControlSurfaceClearHistoryResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        if let dock = windowDockForRouting(routing, tabManager: tabManager) {
            let target = terminalPanel(
                in: dock,
                explicitSurfaceID: surfaceID,
                hasSurfaceIDParam: hasSurfaceIDParam,
                routing: routing
            )
            if target.invalidSurfaceID {
                return .surfaceNotFoundForID
            }
            guard let surfaceId = target.surfaceID else {
                return .noFocusedSurface
            }
            guard let terminalPanel = target.terminalPanel else {
                return .surfaceNotTerminal(surfaceId)
            }
            guard terminalPanel.performBindingAction("clear_screen") else {
                return .bindingActionUnavailable
            }
            terminalPanel.surface.forceRefresh(reason: "terminalController.v2SurfaceClearHistory.windowDock")
            return .cleared(
                windowID: dockResultWindowId(for: dock, tabManager: tabManager),
                workspaceID: dock.workspaceId,
                surfaceID: surfaceId
            )
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        // Legacy: a present-but-unparseable surface_id errors; it must never fall
        // back to clearing the focused surface (wrong-target side effect).
        if hasSurfaceIDParam, surfaceID == nil {
            return .surfaceNotFoundForID
        }
        guard let surfaceId = surfaceID ?? ws.focusedPanelId else {
            return .noFocusedSurface
        }
        guard let terminalPanel = ws.terminalPanel(for: surfaceId) else {
            return .surfaceNotTerminal(surfaceId)
        }
        guard terminalPanel.performBindingAction("clear_screen") else {
            return .bindingActionUnavailable
        }
        terminalPanel.surface.forceRefresh(reason: "terminalController.v2SurfaceClearHistory")
        return .cleared(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            surfaceID: surfaceId
        )
    }

    // MARK: - trigger_flash

    func controlSurfaceTriggerFlash(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?
    ) -> ControlSurfaceTriggerFlashResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        if let dock = windowDockForRouting(routing, tabManager: tabManager) {
            let surfaceId = surfaceID ?? dock.focusedPanelId
            guard let surfaceId else {
                return .noFocusedSurface
            }
            guard dock.panels[surfaceId] != nil else {
                return .surfaceNotFound(surfaceId)
            }
            // `surface.trigger_flash` is not focus intent: flash a visible Dock
            // panel if it is already rendered, but never reveal/raise its window.
            dock.triggerFocusFlash(panelId: surfaceId)
            return .flashed(
                windowID: dockResultWindowId(for: dock, tabManager: tabManager),
                workspaceID: dock.workspaceId,
                surfaceID: surfaceId
            )
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        guard let surfaceId = surfaceID ?? ws.focusedPanelId else {
            return .noFocusedSurface
        }
        guard ws.panels[surfaceId] != nil else {
            return .surfaceNotFound(surfaceId)
        }
        v2MaybeFocusWindow(for: tabManager)
        v2MaybeSelectWorkspace(tabManager, workspace: ws)
        ws.triggerFocusFlash(panelId: surfaceId)
        return .flashed(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            surfaceID: surfaceId
        )
    }

    // MARK: - send_text / send_key

    func controlSurfaceInputStrings() -> ControlSurfaceInputStrings {
        terminalErrorStrings
    }

    /// Resolves the send target surface, matching the legacy
    /// `params["surface_id"] != nil` branch (an explicit param that did not parse
    /// signals `surfaceNotFoundForID`; otherwise the focused surface).
    /// The send-target resolution outcome (a domain value, not an `Error`, so it
    /// is not a `Result.Failure`).
    private enum SendSurfaceTarget {
        case surface(UUID)
        case unresolved(ControlSurfaceSendResolution)
    }

    private func resolveSendSurface(
        in ws: Workspace,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool
    ) -> SendSurfaceTarget {
        if hasSurfaceIDParam {
            guard let surfaceId = surfaceID else {
                return .unresolved(.surfaceNotFoundForID)
            }
            return .surface(surfaceId)
        }
        guard let focused = ws.focusedPanelId else {
            return .unresolved(.noFocusedSurface)
        }
        return .surface(focused)
    }

    func controlSurfaceSendText(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        text: String
    ) -> ControlSurfaceSendResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        if let dock = windowDockForRouting(routing, tabManager: tabManager) {
            let target = terminalPanel(
                in: dock,
                explicitSurfaceID: surfaceID,
                hasSurfaceIDParam: hasSurfaceIDParam,
                routing: routing
            )
            if target.invalidSurfaceID {
                return .surfaceNotFoundForID
            }
            guard let surfaceId = target.surfaceID else {
                return .noFocusedSurface
            }
            guard let terminalPanel = target.terminalPanel else {
                return .surfaceNotTerminal(surfaceId)
            }
            let queued: Bool
            switch terminalPanel.sendInputResult(text) {
            case .sent:
                terminalPanel.surface.forceRefresh(reason: "terminalController.v2SurfaceSendText.windowDock")
                queued = false
            case .queued:
                queued = true
            case .inputQueueFull:
                return .inputQueueFull(surfaceId)
            case .surfaceUnavailable:
                return .surfaceUnavailable(surfaceId)
            case .processExited:
                return .processExited(surfaceId)
            }
            return .sent(
                windowID: dockResultWindowId(for: dock, tabManager: tabManager),
                workspaceID: dock.workspaceId,
                surfaceID: surfaceId,
                queued: queued
            )
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        let surfaceId: UUID
        switch resolveSendSurface(in: ws, surfaceID: surfaceID, hasSurfaceIDParam: hasSurfaceIDParam) {
        case .unresolved(let resolution): return resolution
        case .surface(let id): surfaceId = id
        }
        guard let terminalPanel = ws.terminalPanel(for: surfaceId) else {
            return .surfaceNotTerminal(surfaceId)
        }
        let queued: Bool
        switch terminalPanel.sendInputResult(text) {
        case .sent:
            terminalPanel.surface.forceRefresh(reason: "terminalController.v2SurfaceSendText")
            queued = false
        case .queued:
            queued = true
        case .inputQueueFull:
            return .inputQueueFull(surfaceId)
        case .surfaceUnavailable:
            return .surfaceUnavailable(surfaceId)
        case .processExited:
            return .processExited(surfaceId)
        }
        return .sent(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            surfaceID: surfaceId,
            queued: queued
        )
    }

    func controlSurfaceSendKey(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        key: String
    ) -> ControlSurfaceSendResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        if let dock = windowDockForRouting(routing, tabManager: tabManager) {
            let target = terminalPanel(
                in: dock,
                explicitSurfaceID: surfaceID,
                hasSurfaceIDParam: hasSurfaceIDParam,
                routing: routing
            )
            if target.invalidSurfaceID {
                return .surfaceNotFoundForID
            }
            guard let surfaceId = target.surfaceID else {
                return .noFocusedSurface
            }
            guard let terminalPanel = target.terminalPanel else {
                return .surfaceNotTerminal(surfaceId)
            }
            let sendResult = terminalPanel.sendNamedKeyResult(key)
            switch sendResult {
            case .sent:
                terminalPanel.surface.forceRefresh(reason: "terminalController.v2SurfaceSendKey.windowDock")
            case .queued:
                break
            case .unknownKey:
                return .unknownKey
            case .inputQueueFull:
                return .inputQueueFull(surfaceId)
            case .surfaceUnavailable:
                return .surfaceUnavailable(surfaceId)
            case .processExited:
                return .processExited(surfaceId)
            }
            return .sent(
                windowID: dockResultWindowId(for: dock, tabManager: tabManager),
                workspaceID: dock.workspaceId,
                surfaceID: surfaceId,
                queued: sendResult == .queued
            )
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        let surfaceId: UUID
        switch resolveSendSurface(in: ws, surfaceID: surfaceID, hasSurfaceIDParam: hasSurfaceIDParam) {
        case .unresolved(let resolution): return resolution
        case .surface(let id): surfaceId = id
        }
        guard let terminalPanel = ws.terminalPanel(for: surfaceId) else {
            return .surfaceNotTerminal(surfaceId)
        }
        let sendResult = terminalPanel.sendNamedKeyResult(key)
        switch sendResult {
        case .sent:
            terminalPanel.surface.forceRefresh(reason: "terminalController.v2SurfaceSendKey")
        case .queued:
            break
        case .unknownKey:
            return .unknownKey
        case .inputQueueFull:
            return .inputQueueFull(surfaceId)
        case .surfaceUnavailable:
            return .surfaceUnavailable(surfaceId)
        case .processExited:
            return .processExited(surfaceId)
        }
        return .sent(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            surfaceID: surfaceId,
            queued: sendResult == .queued
        )
    }

    // MARK: - read_text

    func controlSurfaceReadText(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        includeScrollback: Bool,
        lineLimit: Int?
    ) -> ControlSurfaceReadTextResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        if let dock = windowDockForRouting(routing, tabManager: tabManager) {
            let target = terminalPanel(
                in: dock,
                explicitSurfaceID: surfaceID,
                hasSurfaceIDParam: hasSurfaceIDParam,
                routing: routing
            )
            if target.invalidSurfaceID {
                return .surfaceNotFoundForID
            }
            guard let surfaceId = target.surfaceID else {
                return .noFocusedSurface
            }
            guard let terminalPanel = target.terminalPanel else {
                return .surfaceNotTerminal(surfaceId)
            }

            guard let rawSnapshot = readTerminalTextRawSnapshot(
                terminalPanel: terminalPanel,
                includeScrollback: includeScrollback
            ) else {
                return .internalError(message: "Failed to read terminal text")
            }
            switch Self.terminalTextPayload(
                from: rawSnapshot,
                includeScrollback: includeScrollback,
                lineLimit: lineLimit
            ) {
            case .success(let payload):
                return .read(
                    text: payload.text,
                    base64: payload.base64,
                    windowID: dockResultWindowId(for: dock, tabManager: tabManager),
                    workspaceID: dock.workspaceId,
                    surfaceID: surfaceId
                )
            case .failure(let error):
                return .internalError(message: error.message)
            }
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        let surfaceId: UUID
        if hasSurfaceIDParam {
            guard let id = surfaceID else { return .surfaceNotFoundForID }
            surfaceId = id
        } else {
            guard let focused = ws.focusedPanelId else { return .noFocusedSurface }
            surfaceId = focused
        }
        guard let terminalPanel = ws.terminalPanel(for: surfaceId) else {
            return .surfaceNotTerminal(surfaceId)
        }

        guard let rawSnapshot = readTerminalTextRawSnapshot(
            terminalPanel: terminalPanel,
            includeScrollback: includeScrollback
        ) else {
            return .internalError(message: "Failed to read terminal text")
        }
        switch TerminalTextPayload.make(
            from: rawSnapshot,
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        ) {
        case .success(let payload):
            return .read(
                text: payload.text,
                base64: payload.base64,
                windowID: v2ResolveWindowId(tabManager: tabManager),
                workspaceID: ws.id,
                surfaceID: surfaceId
            )
        case .failure(let error):
            return .internalError(message: error.message)
        }
    }

    // MARK: - debug.terminals

    /// `debug.terminals` — the global terminal-surface debug table.
    ///
    /// This body is irreducibly app-coupled: it walks live `NSWindow`,
    /// `NSView`, and `ghostty_surface_t` internals (raw object/surface pointers,
    /// superview class chains, portal-binding/host-lease state, occlusion, key
    /// state) to build a dozens-of-fields-per-terminal `[String: Any]` payload.
    /// Per the refactor LEARNINGS, such a body stays in the executable app
    /// target rather than moving into the control-plane package. The
    /// table-construction logic now lives in the app-side
    /// `TerminalDebugTableBuilder`; this witness still owns the
    /// `appEnvironment` guard (so a `nil` payload maps to the legacy
    /// `unavailable` error when `AppDelegate` is gone), the `v2MainSync`
    /// hop, and the Foundation→`JSONValue` wire bridge. The legacy method
    /// ignored its params, so the seam takes none. The builder receives the two
    /// controller seams it needs (`orderedPanels(in:)` and `v2Ref(kind:uuid:)`).
    func controlDebugTerminals() -> JSONValue? {
        var payload: [String: Any]?

        v2MainSync {
            guard let windowRegistry = appEnvironment?.windowRegistry else { return }
            let builder = TerminalDebugTableBuilder(
                windows: windowRegistry.scriptableMainWindows(),
                surfaces: GhosttyApp.terminalSurfaceRegistry.allTerminalSurfaces(),
                orderedPanels: { self.orderedPanels(in: $0) },
                makeRef: { self.v2Ref(kind: $0, uuid: $1) }
            )
            payload = builder.build()
        }

        guard let payload else { return nil }
        return JSONValue(foundationObject: payload)
    }
}
