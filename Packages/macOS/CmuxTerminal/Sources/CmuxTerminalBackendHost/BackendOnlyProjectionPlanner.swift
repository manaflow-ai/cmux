internal import CmuxTerminalBackend
internal import Foundation

/// Derives one bounded, immutable presentation plan from daemon-owned state.
nonisolated struct BackendOnlyProjectionPlanner: Sendable {
    static let maximumVisibleLeafCount = 256

    func plan(
        topology: CanonicalTopology,
        navigation: BackendOnlyProjectionNavigationInput
    ) throws -> BackendOnlyProjectionPlan {
        var counters = BackendOnlyProjectionPlannerCounters()
        let workspacesByID = indexWorkspaces(
            topology.workspaces,
            counters: &counters
        )
        let navigationWorkspacesByID = try indexNavigationWorkspaces(
            navigation.workspaces,
            counters: &counters
        )

        guard let selectedWorkspaceID = navigation.selectedWorkspaceID else {
            throw BackendOnlyProjectionPlannerError.selectedWorkspaceRequired
        }
        guard let workspace = workspacesByID[selectedWorkspaceID] else {
            throw BackendOnlyProjectionPlannerError.selectedWorkspaceMissing(
                selectedWorkspaceID
            )
        }
        guard let workspaceNavigation = navigationWorkspacesByID[selectedWorkspaceID] else {
            throw BackendOnlyProjectionPlannerError.navigationWorkspaceMissing(
                selectedWorkspaceID
            )
        }

        let screensByID = indexScreens(
            workspace.screens,
            counters: &counters
        )
        let navigationScreensByID = try indexNavigationScreens(
            workspaceNavigation.screens,
            counters: &counters
        )
        let selectedScreenID = workspaceNavigation.selectedScreenID
        guard let screen = screensByID[selectedScreenID] else {
            throw BackendOnlyProjectionPlannerError.selectedScreenMissing(
                workspaceID: selectedWorkspaceID,
                screenID: selectedScreenID
            )
        }
        guard let screenNavigation = navigationScreensByID[selectedScreenID] else {
            throw BackendOnlyProjectionPlannerError.navigationScreenMissing(
                workspaceID: selectedWorkspaceID,
                screenID: selectedScreenID
            )
        }

        let paneIndexes = indexPanes(screen.panes, counters: &counters)
        let navigationPanesByID = try indexNavigationPanes(
            screenNavigation.panes,
            screenID: selectedScreenID,
            canonicalPanesByID: paneIndexes.byID,
            counters: &counters
        )
        guard let activePane = paneIndexes.byID[screenNavigation.activePaneID] else {
            throw BackendOnlyProjectionPlannerError.activePaneMissing(
                screenID: selectedScreenID,
                paneID: screenNavigation.activePaneID
            )
        }
        if let zoomedPaneID = screenNavigation.zoomedPaneID,
           zoomedPaneID != screenNavigation.activePaneID {
            throw BackendOnlyProjectionPlannerError.zoomedPaneMustBeActive(
                screenID: selectedScreenID,
                activePaneID: screenNavigation.activePaneID,
                zoomedPaneID: zoomedPaneID
            )
        }

        let visibleCanonicalLayout: CanonicalLayout
        if screenNavigation.zoomedPaneID == nil {
            visibleCanonicalLayout = screen.layout
        } else {
            visibleCanonicalLayout = .leaf(
                pane: activePane.id,
                paneUUID: activePane.uuid
            )
        }
        let visibleLeafCount = try countVisibleLeaves(
            in: visibleCanonicalLayout,
            panesByID: paneIndexes.byID,
            panesByNumber: paneIndexes.byNumber,
            depth: 1,
            counters: &counters
        )
        guard visibleLeafCount <= Self.maximumVisibleLeafCount else {
            throw BackendOnlyProjectionPlannerError.visibleLeafLimitExceeded(
                actual: visibleLeafCount,
                maximum: Self.maximumVisibleLeafCount
            )
        }

        var descriptors: [BackendOnlyProjectionPaneDescriptor] = []
        descriptors.reserveCapacity(visibleLeafCount)
        let layout = try materialize(
            visibleCanonicalLayout,
            logicalPresentationID: navigation.logicalPresentationID,
            workspace: workspace,
            screen: screen,
            screenNavigation: screenNavigation,
            panesByID: paneIndexes.byID,
            panesByNumber: paneIndexes.byNumber,
            navigationPanesByID: navigationPanesByID,
            depth: 1,
            descriptors: &descriptors,
            counters: &counters
        )

        return BackendOnlyProjectionPlan(
            logicalPresentationID: navigation.logicalPresentationID,
            workspaceID: workspace.uuid,
            numericWorkspaceID: workspace.id,
            workspaceName: workspace.name,
            screenID: screen.uuid,
            numericScreenID: screen.id,
            screenName: screen.name,
            activePaneID: screenNavigation.activePaneID,
            zoomedPaneID: screenNavigation.zoomedPaneID,
            layout: layout,
            panes: descriptors,
            metrics: counters.snapshot(visibleLeafCount: visibleLeafCount)
        )
    }

    private func indexWorkspaces(
        _ workspaces: [CanonicalWorkspace],
        counters: inout BackendOnlyProjectionPlannerCounters
    ) -> [WorkspaceID: CanonicalWorkspace] {
        var result: [WorkspaceID: CanonicalWorkspace] = [:]
        result.reserveCapacity(workspaces.count)
        for workspace in workspaces {
            counters.topologyWorkspaceIndexVisits += 1
            result[workspace.uuid] = workspace
        }
        return result
    }

    private func indexNavigationWorkspaces(
        _ workspaces: [BackendOnlyProjectionWorkspaceNavigation],
        counters: inout BackendOnlyProjectionPlannerCounters
    ) throws -> [WorkspaceID: BackendOnlyProjectionWorkspaceNavigation] {
        var result: [WorkspaceID: BackendOnlyProjectionWorkspaceNavigation] = [:]
        result.reserveCapacity(workspaces.count)
        for workspace in workspaces {
            counters.navigationWorkspaceIndexVisits += 1
            guard result.updateValue(workspace, forKey: workspace.workspaceID) == nil else {
                throw BackendOnlyProjectionPlannerError.duplicateNavigationWorkspace(
                    workspace.workspaceID
                )
            }
        }
        return result
    }

    private func indexScreens(
        _ screens: [CanonicalScreen],
        counters: inout BackendOnlyProjectionPlannerCounters
    ) -> [ScreenID: CanonicalScreen] {
        var result: [ScreenID: CanonicalScreen] = [:]
        result.reserveCapacity(screens.count)
        for screen in screens {
            counters.selectedWorkspaceScreenIndexVisits += 1
            result[screen.uuid] = screen
        }
        return result
    }

    private func indexNavigationScreens(
        _ screens: [BackendOnlyProjectionScreenNavigation],
        counters: inout BackendOnlyProjectionPlannerCounters
    ) throws -> [ScreenID: BackendOnlyProjectionScreenNavigation] {
        var result: [ScreenID: BackendOnlyProjectionScreenNavigation] = [:]
        result.reserveCapacity(screens.count)
        for screen in screens {
            counters.selectedNavigationScreenIndexVisits += 1
            guard result.updateValue(screen, forKey: screen.screenID) == nil else {
                throw BackendOnlyProjectionPlannerError.duplicateNavigationScreen(
                    screen.screenID
                )
            }
        }
        return result
    }

    private func indexPanes(
        _ panes: [CanonicalPane],
        counters: inout BackendOnlyProjectionPlannerCounters
    ) -> (
        byID: [PaneID: CanonicalPane],
        byNumber: [UInt64: CanonicalPane]
    ) {
        var byID: [PaneID: CanonicalPane] = [:]
        var byNumber: [UInt64: CanonicalPane] = [:]
        byID.reserveCapacity(panes.count)
        byNumber.reserveCapacity(panes.count)
        for pane in panes {
            counters.selectedScreenPaneIndexVisits += 1
            byID[pane.uuid] = pane
            byNumber[pane.id] = pane
        }
        return (byID, byNumber)
    }

    private func indexNavigationPanes(
        _ panes: [BackendOnlyProjectionPaneNavigation],
        screenID: ScreenID,
        canonicalPanesByID: [PaneID: CanonicalPane],
        counters: inout BackendOnlyProjectionPlannerCounters
    ) throws -> [PaneID: BackendOnlyProjectionPaneNavigation] {
        var result: [PaneID: BackendOnlyProjectionPaneNavigation] = [:]
        result.reserveCapacity(panes.count)
        for pane in panes {
            counters.selectedNavigationPaneIndexVisits += 1
            guard result.updateValue(pane, forKey: pane.paneID) == nil else {
                throw BackendOnlyProjectionPlannerError.duplicateNavigationPane(
                    pane.paneID
                )
            }
            guard canonicalPanesByID[pane.paneID] != nil else {
                throw BackendOnlyProjectionPlannerError.navigationPaneOutsideSelectedScreen(
                    screenID: screenID,
                    paneID: pane.paneID
                )
            }
        }
        return result
    }

    private func countVisibleLeaves(
        in layout: CanonicalLayout,
        panesByID: [PaneID: CanonicalPane],
        panesByNumber: [UInt64: CanonicalPane],
        depth: Int,
        counters: inout BackendOnlyProjectionPlannerCounters
    ) throws -> Int {
        guard depth <= CanonicalLayout.maximumDepth else {
            throw BackendOnlyProjectionPlannerError.layoutDepthExceeded(
                actual: depth,
                maximum: CanonicalLayout.maximumDepth
            )
        }
        counters.visibleLeafCountNodeVisits += 1
        switch layout {
        case .leaf(let numericPaneID, let paneID):
            _ = try pane(
                numericPaneID: numericPaneID,
                paneID: paneID,
                panesByID: panesByID,
                panesByNumber: panesByNumber
            )
            return 1
        case .split(_, _, let first, let second):
            let firstCount = try countVisibleLeaves(
                in: first,
                panesByID: panesByID,
                panesByNumber: panesByNumber,
                depth: depth + 1,
                counters: &counters
            )
            let secondCount = try countVisibleLeaves(
                in: second,
                panesByID: panesByID,
                panesByNumber: panesByNumber,
                depth: depth + 1,
                counters: &counters
            )
            return firstCount + secondCount
        }
    }

    private func materialize(
        _ layout: CanonicalLayout,
        logicalPresentationID: UUID,
        workspace: CanonicalWorkspace,
        screen: CanonicalScreen,
        screenNavigation: BackendOnlyProjectionScreenNavigation,
        panesByID: [PaneID: CanonicalPane],
        panesByNumber: [UInt64: CanonicalPane],
        navigationPanesByID: [PaneID: BackendOnlyProjectionPaneNavigation],
        depth: Int,
        descriptors: inout [BackendOnlyProjectionPaneDescriptor],
        counters: inout BackendOnlyProjectionPlannerCounters
    ) throws -> BackendOnlyProjectionLayout {
        guard depth <= CanonicalLayout.maximumDepth else {
            throw BackendOnlyProjectionPlannerError.layoutDepthExceeded(
                actual: depth,
                maximum: CanonicalLayout.maximumDepth
            )
        }
        counters.materializedLayoutNodeVisits += 1
        switch layout {
        case .leaf(let numericPaneID, let paneID):
            let pane = try pane(
                numericPaneID: numericPaneID,
                paneID: paneID,
                panesByID: panesByID,
                panesByNumber: panesByNumber
            )
            guard let paneNavigation = navigationPanesByID[paneID] else {
                throw BackendOnlyProjectionPlannerError.navigationPaneMissing(paneID)
            }
            let projected = try descriptor(
                logicalPresentationID: logicalPresentationID,
                workspace: workspace,
                screen: screen,
                pane: pane,
                paneNavigation: paneNavigation,
                activePaneID: screenNavigation.activePaneID,
                counters: &counters
            )
            descriptors.append(projected)
            return .pane(projected.slotID)
        case .split(let direction, let ratio, let first, let second):
            return .split(
                direction: direction,
                ratio: ratio,
                first: try materialize(
                    first,
                    logicalPresentationID: logicalPresentationID,
                    workspace: workspace,
                    screen: screen,
                    screenNavigation: screenNavigation,
                    panesByID: panesByID,
                    panesByNumber: panesByNumber,
                    navigationPanesByID: navigationPanesByID,
                    depth: depth + 1,
                    descriptors: &descriptors,
                    counters: &counters
                ),
                second: try materialize(
                    second,
                    logicalPresentationID: logicalPresentationID,
                    workspace: workspace,
                    screen: screen,
                    screenNavigation: screenNavigation,
                    panesByID: panesByID,
                    panesByNumber: panesByNumber,
                    navigationPanesByID: navigationPanesByID,
                    depth: depth + 1,
                    descriptors: &descriptors,
                    counters: &counters
                )
            )
        }
    }

    private func pane(
        numericPaneID: UInt64,
        paneID: PaneID,
        panesByID: [PaneID: CanonicalPane],
        panesByNumber: [UInt64: CanonicalPane]
    ) throws -> CanonicalPane {
        guard let stablePane = panesByID[paneID],
              let numericPane = panesByNumber[numericPaneID],
              stablePane.id == numericPaneID,
              numericPane.uuid == paneID else {
            throw BackendOnlyProjectionPlannerError.layoutPaneIdentityMismatch(
                numericPaneID: numericPaneID,
                paneID: paneID
            )
        }
        return stablePane
    }

    private func descriptor(
        logicalPresentationID: UUID,
        workspace: CanonicalWorkspace,
        screen: CanonicalScreen,
        pane: CanonicalPane,
        paneNavigation: BackendOnlyProjectionPaneNavigation,
        activePaneID: PaneID,
        counters: inout BackendOnlyProjectionPlannerCounters
    ) throws -> BackendOnlyProjectionPaneDescriptor {
        var tabs: [BackendOnlyProjectionTabMetadata] = []
        tabs.reserveCapacity(pane.tabs.count)
        var selectedSurface: CanonicalSurface?
        for surface in pane.tabs {
            counters.tabMetadataVisits += 1
            let isSelected = surface.uuid == paneNavigation.selectedSurfaceID
            if isSelected {
                selectedSurface = surface
            }
            tabs.append(
                BackendOnlyProjectionTabMetadata(
                    surfaceID: surface.uuid,
                    numericSurfaceID: surface.id,
                    kind: surface.kind,
                    name: surface.name,
                    browserEndpoint: surface.browserEndpoint,
                    externalTerminalProvenance: surface.externalTerminalProvenance,
                    isSelected: isSelected
                )
            )
        }
        guard let selectedSurface else {
            throw BackendOnlyProjectionPlannerError.selectedSurfaceMissing(
                paneID: pane.uuid,
                surfaceID: paneNavigation.selectedSurfaceID
            )
        }
        let slotID = BackendOnlyProjectionSlotID(
            logicalPresentationID: logicalPresentationID,
            workspaceID: workspace.uuid,
            screenID: screen.uuid,
            paneID: pane.uuid
        )
        return BackendOnlyProjectionPaneDescriptor(
            slotID: slotID,
            paneID: pane.uuid,
            numericPaneID: pane.id,
            paneName: pane.name,
            isActive: pane.uuid == activePaneID,
            tabs: tabs,
            content: content(
                for: selectedSurface,
                workspace: workspace,
                screen: screen,
                pane: pane
            )
        )
    }

    private func content(
        for surface: CanonicalSurface,
        workspace: CanonicalWorkspace,
        screen: CanonicalScreen,
        pane: CanonicalPane
    ) -> BackendOnlyProjectionPaneContent {
        let normalizedKind = asciiLowercased(surface.kind)
        switch normalizedKind {
        case "terminal", "pty":
            return .terminal(
                BackendOnlyTerminalSelection(
                    workspaceID: workspace.uuid,
                    screenID: screen.uuid,
                    paneID: pane.uuid,
                    surfaceID: surface.uuid,
                    numericSurfaceID: surface.id
                )
            )
        case "browser":
            return .browserPlaceholder(
                surfaceID: surface.uuid,
                numericSurfaceID: surface.id,
                endpoint: surface.browserEndpoint
            )
        default:
            return .unsupportedPlaceholder(
                surfaceID: surface.uuid,
                numericSurfaceID: surface.id,
                kind: surface.kind
            )
        }
    }

    private func asciiLowercased(_ value: String) -> String {
        var bytes = Array(value.utf8)
        for index in bytes.indices where bytes[index] >= 65 && bytes[index] <= 90 {
            bytes[index] += 32
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
