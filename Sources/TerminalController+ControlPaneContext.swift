import AppKit
import Bonsplit
import CmuxControlSocket
import Foundation

/// The pane-domain witnesses are the byte-faithful bodies of the former
/// `v2Pane*` dispatchers, minus the per-read `v2MainSync` hop: the coordinator
/// already runs on the main actor inside the socket-command policy scope, so each
/// hop would re-apply the identical thread-local focus-allowance stack — a no-op.
///
/// App-coupled resolution (`resolveTabManager(routing:)`, `v2LocatePane`,
/// `v2ResolveWindowId`, the Bonsplit layout, the split-resize candidate
/// collection) stays here; the seam exposes only Sendable snapshots and
/// resolution enums.
extension TerminalController: ControlPaneContext {
    func controlPaneRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool {
        resolveTabManager(routing: routing) != nil
    }

    // MARK: - Routing helpers

    /// The routing twin of the legacy `v2ResolveWorkspace(params:tabManager:)`,
    /// reading the selectors the coordinator already resolved.
    private func resolveWorkspace(
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

    // MARK: - list

    func controlPaneList(routing: ControlRoutingSelectors) -> ControlPaneListSnapshot? {
        guard let tabManager = resolveTabManager(routing: routing),
              let ws = resolveWorkspace(routing: routing, tabManager: tabManager) else {
            return nil
        }

        let focusedPaneId = ws.bonsplitController.focusedPaneId
        let snapshot = ws.bonsplitController.layoutSnapshot()
        let geometryByPaneId = Dictionary(
            snapshot.panes.map { ($0.paneId, $0.frame) },
            uniquingKeysWith: { first, _ in first }
        )

        let panes: [ControlPaneSummary] = ws.bonsplitController.allPaneIds.map { paneId in
            let tabs = ws.bonsplitController.tabs(inPane: paneId)
            let surfaceUUIDs: [UUID] = tabs.compactMap { ws.panelIdFromSurfaceId($0.id) }
            let selectedTab = ws.bonsplitController.selectedTab(inPane: paneId)
            let selectedSurfaceUUID = selectedTab.flatMap { ws.panelIdFromSurfaceId($0.id) }

            let pixelFrame: ControlPanePixelFrame? = geometryByPaneId[paneId.id.uuidString].map { frame in
                ControlPanePixelFrame(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
            }

            var gridSize: ControlPaneGridSize?
            if let panelUUID = selectedSurfaceUUID,
               let panel = ws.panels[panelUUID] as? TerminalPanel,
               panel.surface.hasLiveSurface,
               let ghosttySurface = panel.surface.surface {
                let size = ghostty_surface_size(ghosttySurface)
                if size.columns > 0 && size.rows > 0 {
                    gridSize = ControlPaneGridSize(
                        columns: Int(size.columns),
                        rows: Int(size.rows),
                        cellWidthPx: Int(size.cell_width_px),
                        cellHeightPx: Int(size.cell_height_px)
                    )
                }
            }

            return ControlPaneSummary(
                paneID: paneId.id,
                isFocused: paneId == focusedPaneId,
                surfaceIDs: surfaceUUIDs,
                selectedSurfaceID: selectedSurfaceUUID,
                pixelFrame: pixelFrame,
                gridSize: gridSize
            )
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return ControlPaneListSnapshot(
            workspaceID: ws.id,
            windowID: windowId,
            panes: panes,
            containerWidth: snapshot.containerFrame.width,
            containerHeight: snapshot.containerFrame.height
        )
    }

    // MARK: - focus

    func controlPaneFocus(
        routing: ControlRoutingSelectors,
        paneID: UUID
    ) -> ControlPaneFocusResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let ws = resolveWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        guard let paneId = ws.bonsplitController.allPaneIds.first(where: { $0.id == paneID }) else {
            return .paneNotFound(paneID)
        }
        if let windowId = v2ResolveWindowId(tabManager: tabManager) {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
            setActiveTabManager(tabManager)
        }
        if tabManager.selectedTabId != ws.id {
            tabManager.selectWorkspace(ws)
        }
        ws.bonsplitController.focusPane(paneId)
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .focused(windowID: windowId, workspaceID: ws.id, paneID: paneId.id)
    }

    // MARK: - surfaces

    func controlPaneSurfaces(
        routing: ControlRoutingSelectors,
        paneID: UUID?
    ) -> ControlPaneSurfacesSnapshot? {
        guard let tabManager = resolveTabManager(routing: routing),
              let ws = resolveWorkspace(routing: routing, tabManager: tabManager) else {
            return nil
        }

        let paneId: PaneID? = {
            if let paneID {
                return ws.bonsplitController.allPaneIds.first(where: { $0.id == paneID })
            }
            return ws.bonsplitController.focusedPaneId
        }()
        guard let paneId else { return nil }

        let selectedTab = ws.bonsplitController.selectedTab(inPane: paneId)
        let tabs = ws.bonsplitController.tabs(inPane: paneId)

        let surfaces: [ControlPaneSurfaceSummary] = tabs.map { tab in
            let panelId = ws.panelIdFromSurfaceId(tab.id)
            let panel = panelId.flatMap { ws.panels[$0] }
            return ControlPaneSurfaceSummary(
                surfaceID: panelId,
                title: tab.title,
                typeRawValue: panel?.panelType.rawValue,
                isSelected: tab.id == selectedTab?.id
            )
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return ControlPaneSurfacesSnapshot(
            workspaceID: ws.id,
            paneID: paneId.id,
            windowID: windowId,
            surfaces: surfaces
        )
    }

    // MARK: - create

    func controlPaneCreate(
        routing: ControlRoutingSelectors,
        inputs: ControlPaneCreateInputs
    ) -> ControlPaneCreateResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let directionRaw = inputs.directionRaw,
              let direction = parseSplitDirection(directionRaw) else {
            return .invalidDirection
        }

        let panelType: PanelType = inputs.typeRaw.flatMap { self.panelType(forRawToken: $0) } ?? .terminal
        if panelType == .agentSession {
            return .agentSessionRejected(typeRawValue: panelType.rawValue)
        }
        let url = inputs.urlRaw.flatMap { URL(string: $0) }
        if panelType == .browser, BrowserAvailabilitySettings.isDisabled() {
            return browserDisabledCreateResolution(rawURL: inputs.urlRaw, url: url, tabManager: tabManager)
        }

        let orientation = direction.orientation
        let insertFirst = direction.insertFirst

        var initialDividerPosition: Double?
        if inputs.hasInitialDividerPosition {
            guard let rawPosition = inputs.initialDividerPositionRaw, rawPosition.isFinite else {
                return .invalidDividerPosition
            }
            initialDividerPosition = min(max(rawPosition, 0.1), 0.9)
        }

        guard let ws = resolveWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        v2MaybeFocusWindow(for: tabManager)
        v2MaybeSelectWorkspace(tabManager, workspace: ws)
        guard let sourcePanelId = inputs.requestedSourceSurfaceID ?? ws.focusedPanelId,
              ws.panels[sourcePanelId] != nil else {
            return .noSourceSurface
        }

        if ws.isRemoteTmuxMirror, panelType == .terminal {
            let unsupported = mirrorRoutedUnsupportedOptions(
                insertFirst: insertFirst,
                workingDirectory: inputs.workingDirectory,
                initialCommand: inputs.initialCommand,
                tmuxStartCommand: inputs.tmuxStartCommand,
                startupEnvironment: inputs.startupEnvironment,
                initialDividerPosition: initialDividerPosition
            )
            if !unsupported.isEmpty {
                return .mirrorUnsupportedOptions(unsupported)
            }
        }

        let newPanelId: UUID?
        let focus = v2FocusAllowed(requested: inputs.requestedFocus)
        if panelType == .browser {
            newPanelId = ws.newBrowserSplit(
                from: sourcePanelId,
                orientation: orientation,
                insertFirst: insertFirst,
                url: url,
                focus: focus,
                creationPolicy: .automationPreload,
                initialDividerPosition: initialDividerPosition.map { CGFloat($0) }
            )?.id
        } else {
            switch ws.newTerminalSplitOutcome(
                from: sourcePanelId,
                orientation: orientation,
                insertFirst: insertFirst,
                focus: focus,
                workingDirectory: inputs.workingDirectory,
                initialCommand: inputs.initialCommand,
                tmuxStartCommand: inputs.tmuxStartCommand,
                startupEnvironment: inputs.startupEnvironment,
                initialDividerPosition: initialDividerPosition.map { CGFloat($0) }
            ) {
            case .created(let panel):
                newPanelId = panel.id
            case .routedToRemote:
                return .routedToRemote(
                    windowID: v2ResolveWindowId(tabManager: tabManager),
                    workspaceID: ws.id,
                    typeRawValue: panelType.rawValue
                )
            case .failed:
                newPanelId = nil
            }
        }

        guard let newPanelId else {
            return .createFailed
        }
        let paneUUID = ws.paneId(forPanelId: newPanelId)?.id
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .created(
            windowID: windowId,
            workspaceID: ws.id,
            paneID: paneUUID,
            surfaceID: newPanelId,
            typeRawValue: panelType.rawValue
        )
    }

    /// The byte-faithful twin of `v2PanelType`, mapping a raw token to a
    /// `PanelType` (used only by the create path; the coordinator passes the raw
    /// string so Bonsplit/PanelType stay app-side).
    private func panelType(forRawToken raw: String) -> PanelType? {
        switch v2NormalizedToken(raw) {
        case "terminal":
            return .terminal
        case "browser":
            return .browser
        case "markdown":
            return .markdown
        case "filepreview":
            return .filePreview
        case "rightsidebartool":
            return .rightSidebarTool
        case "agentsession":
            return .agentSession
        default:
            return nil
        }
    }

    /// The byte-faithful twin of `v2BrowserDisabledExternalOpenResult`, mapped
    /// onto ``ControlPaneCreateResolution``.
    private func browserDisabledCreateResolution(
        rawURL: String?,
        url: URL?,
        tabManager: TabManager?
    ) -> ControlPaneCreateResolution {
        if let rawURL, url == nil {
            return .browserDisabledInvalidURL(rawURL: rawURL)
        }
        guard let url else {
            return .browserDisabledNoURL
        }
        guard NSWorkspace.shared.open(url) else {
            return .browserDisabledExternalOpenFailed(url: url.absoluteString)
        }
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .browserDisabledOpenedExternally(windowID: windowId, url: url.absoluteString)
    }

    // MARK: - resize

    func controlPaneResize(
        routing: ControlRoutingSelectors,
        inputs: ControlPaneResizeInputs
    ) -> ControlPaneResizeResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let ws = resolveWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }

        let paneUUID = inputs.paneID ?? ws.bonsplitController.focusedPaneId?.id
        guard let paneUUID else {
            return .noFocusedPane
        }
        guard ws.bonsplitController.allPaneIds.contains(where: { $0.id == paneUUID }) else {
            return .paneNotFound(paneUUID)
        }

        let tree = ws.bonsplitController.treeSnapshot()
        var candidates: [V2PaneResizeCandidate] = []
        let trace = v2PaneResizeCollectCandidates(
            node: tree,
            targetPaneId: paneUUID.uuidString,
            candidates: &candidates
        )
        guard trace.containsTarget else {
            return .paneNotFoundInTree(paneUUID)
        }

        if let absoluteAxis = inputs.absoluteAxis,
           let targetPixels = inputs.targetPixels,
           let absoluteResize = v2SetAbsolutePaneSize(
                workspace: ws,
                paneUUID: paneUUID,
                axis: absoluteAxis,
                targetPixels: CGFloat(targetPixels)
           ) {
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            return .absoluteResized(
                windowID: windowId,
                workspaceID: ws.id,
                paneID: paneUUID,
                splitID: absoluteResize.splitId,
                absoluteAxis: absoluteAxis,
                targetPixels: targetPixels,
                oldDividerPosition: Double(absoluteResize.oldPosition),
                newDividerPosition: Double(absoluteResize.newPosition)
            )
        } else if inputs.absoluteAxis != nil || inputs.targetPixels != nil {
            return .noAbsoluteSplitAncestor(paneID: paneUUID, absoluteAxis: inputs.absoluteAxis)
        }

        guard let direction = inputs.direction.flatMap(V2PaneResizeDirection.init(rawValue:)) else {
            // Unreachable: the coordinator pre-validates the relative path.
            return .noAdjacentBorder(paneID: paneUUID, direction: inputs.direction ?? "")
        }

        let orientationMatches = candidates.filter { $0.orientation == direction.splitOrientation }
        guard !orientationMatches.isEmpty else {
            return .noOrientationSplitAncestor(
                paneID: paneUUID,
                orientation: direction.splitOrientation,
                direction: direction.rawValue
            )
        }

        guard let candidate = orientationMatches.first(where: {
            $0.paneInFirstChild == direction.requiresPaneInFirstChild
        }) else {
            return .noAdjacentBorder(paneID: paneUUID, direction: direction.rawValue)
        }

        let delta = CGFloat(inputs.amount) / candidate.axisPixels
        let requested = candidate.dividerPosition + (direction.dividerDeltaSign * delta)
        let clamped = min(max(requested, 0.1), 0.9)
        guard ws.bonsplitController.setDividerPosition(clamped, forSplit: candidate.splitId, fromExternal: true) else {
            return .setDividerFailed(splitID: candidate.splitId)
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .relativeResized(
            windowID: windowId,
            workspaceID: ws.id,
            paneID: paneUUID,
            splitID: candidate.splitId,
            direction: direction.rawValue,
            amount: inputs.amount,
            oldDividerPosition: Double(candidate.dividerPosition),
            newDividerPosition: Double(clamped)
        )
    }

    // MARK: - swap

    func controlPaneSwap(
        sourcePaneID: UUID,
        targetPaneID: UUID,
        requestedFocus: Bool
    ) -> ControlPaneSwapResolution {
        let focus = v2FocusAllowed(requested: requestedFocus)
        guard let located = v2LocatePane(sourcePaneID) else {
            return .sourcePaneNotFound(sourcePaneID)
        }
        guard let targetPane = located.workspace.bonsplitController.allPaneIds.first(where: {
            $0.id == targetPaneID
        }) else {
            return .targetPaneNotFound(targetPaneID)
        }
        let workspace = located.workspace
        let sourcePane = located.paneId

        guard let selectedSourceTab = workspace.bonsplitController.selectedTab(inPane: sourcePane),
              let selectedTargetTab = workspace.bonsplitController.selectedTab(inPane: targetPane),
              let sourceSurfaceId = workspace.panelIdFromSurfaceId(selectedSourceTab.id),
              let targetSurfaceId = workspace.panelIdFromSurfaceId(selectedTargetTab.id) else {
            return .bothPanesNeedSurface
        }

        // Keep pane identities stable during swap when one side has a single surface.
        var sourcePlaceholder: UUID?
        var targetPlaceholder: UUID?
        if workspace.bonsplitController.tabs(inPane: sourcePane).count <= 1 {
            sourcePlaceholder = workspace.newTerminalSurface(inPane: sourcePane, focus: false)?.id
            if sourcePlaceholder == nil {
                return .sourcePlaceholderFailed
            }
        }
        if workspace.bonsplitController.tabs(inPane: targetPane).count <= 1 {
            targetPlaceholder = workspace.newTerminalSurface(inPane: targetPane, focus: false)?.id
            if targetPlaceholder == nil {
                return .targetPlaceholderFailed
            }
        }

        guard workspace.moveSurface(panelId: sourceSurfaceId, toPane: targetPane, focus: false) else {
            return .moveSourceFailed
        }
        guard workspace.moveSurface(panelId: targetSurfaceId, toPane: sourcePane, focus: false) else {
            return .moveTargetFailed
        }

        if let sourcePlaceholder {
            _ = workspace.closePanel(sourcePlaceholder, force: true)
        }
        if let targetPlaceholder {
            _ = workspace.closePanel(targetPlaceholder, force: true)
        }

        if focus {
            workspace.bonsplitController.focusPane(targetPane)
        }
        return .swapped(
            windowID: located.windowId,
            workspaceID: workspace.id,
            sourcePaneID: sourcePane.id,
            targetPaneID: targetPane.id,
            sourceSurfaceID: sourceSurfaceId,
            targetSurfaceID: targetSurfaceId
        )
    }

    // MARK: - break

    func controlPaneBreak(
        routing: ControlRoutingSelectors,
        paneID: UUID?,
        surfaceID: UUID?,
        requestedFocus: Bool
    ) -> ControlPaneBreakResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        let focus = v2FocusAllowed(requested: requestedFocus)
        guard let sourceWorkspace = resolveWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }

        let sourcePane: PaneID? = {
            if let paneID {
                return sourceWorkspace.bonsplitController.allPaneIds.first(where: { $0.id == paneID })
            }
            return sourceWorkspace.bonsplitController.focusedPaneId
        }()

        let resolvedSurfaceId: UUID? = {
            if let surfaceID { return surfaceID }
            if let sourcePane,
               let selected = sourceWorkspace.bonsplitController.selectedTab(inPane: sourcePane) {
                return sourceWorkspace.panelIdFromSurfaceId(selected.id)
            }
            return sourceWorkspace.focusedPanelId
        }()
        guard let surfaceId = resolvedSurfaceId else {
            return .noSourceSurface
        }
        guard sourceWorkspace.panels[surfaceId] != nil else {
            return .surfaceNotFound(surfaceId)
        }
        let sourceIndex = sourceWorkspace.indexInPane(forPanelId: surfaceId)
        let sourcePaneForRollback = sourceWorkspace.paneId(forPanelId: surfaceId)

        guard let detached = sourceWorkspace.detachSurface(panelId: surfaceId) else {
            return .detachFailed
        }

        guard let destinationWorkspace = tabManager.addWorkspace(
            fromDetachedSurface: detached,
            select: focus
        ) else {
            if let sourcePaneForRollback {
                _ = sourceWorkspace.attachDetachedSurface(
                    detached,
                    inPane: sourcePaneForRollback,
                    atIndex: sourceIndex,
                    focus: true
                )
            }
            return .createWorkspaceFailed
        }
        guard let destinationPaneId = destinationWorkspace.paneId(forPanelId: surfaceId)?.id else {
            return .destinationPaneUnresolved(workspaceID: destinationWorkspace.id, surfaceID: surfaceId)
        }
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .broken(
            windowID: windowId,
            workspaceID: destinationWorkspace.id,
            paneID: destinationPaneId,
            surfaceID: surfaceId
        )
    }

    // MARK: - join

    func controlPaneJoin(
        targetPaneID: UUID,
        surfaceID: UUID?,
        sourcePaneID: UUID?,
        hasFocusParam: Bool,
        focus: Bool
    ) -> ControlPaneJoinResolution {
        var resolvedSurfaceId = surfaceID
        if resolvedSurfaceId == nil, let sourcePaneID {
            guard let sourceLocated = v2LocatePane(sourcePaneID),
                  let selected = sourceLocated.workspace.bonsplitController.selectedTab(inPane: sourceLocated.paneId),
                  let selectedSurface = sourceLocated.workspace.panelIdFromSurfaceId(selected.id) else {
                return .sourceSurfaceUnresolved(sourcePaneID: sourcePaneID)
            }
            resolvedSurfaceId = selectedSurface
        }
        guard let surfaceId = resolvedSurfaceId else {
            return .missingSurface
        }

        var moveParams: [String: Any] = [
            "surface_id": surfaceId.uuidString,
            "pane_id": targetPaneID.uuidString,
        ]
        if hasFocusParam {
            moveParams["focus"] = focus
        }
        return .moved(v2SurfaceMoveControlResult(params: moveParams))
    }

    /// Runs the legacy `v2SurfaceMove` and bridges its Foundation-shaped
    /// `V2CallResult` to the typed `ControlCallResult` (the exact pattern
    /// `bridgeMobileResult` uses), so `pane.join` forwards the surface-move
    /// outcome byte-faithfully. `v2SurfaceMove` is currently `private`; the
    /// integrator must relax it to at least `internal` (it lives in
    /// `TerminalController.swift`, which this extension cannot reach while
    /// `private`).
    private func v2SurfaceMoveControlResult(params: [String: Any]) -> ControlCallResult {
        switch v2SurfaceMove(params: params) {
        case let .ok(payload):
            return .ok(JSONValue(foundationObject: payload) ?? .object([:]))
        case let .err(code, message, data):
            return .err(
                code: code,
                message: message,
                data: data.flatMap { JSONValue(foundationObject: $0) }
            )
        }
    }

    // MARK: - last

    func controlPaneLast(routing: ControlRoutingSelectors) -> ControlPaneLastResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let ws = resolveWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        guard let focused = ws.bonsplitController.focusedPaneId else {
            return .noFocusedPane
        }
        guard let target = ws.bonsplitController.allPaneIds.first(where: { $0.id != focused.id }) else {
            return .noAlternatePane
        }

        ws.bonsplitController.focusPane(target)
        let selectedSurfaceId = ws.bonsplitController.selectedTab(inPane: target)
            .flatMap { ws.panelIdFromSurfaceId($0.id) }
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .focused(
            windowID: windowId,
            workspaceID: ws.id,
            paneID: target.id,
            selectedSurfaceID: selectedSurfaceId
        )
    }
}
