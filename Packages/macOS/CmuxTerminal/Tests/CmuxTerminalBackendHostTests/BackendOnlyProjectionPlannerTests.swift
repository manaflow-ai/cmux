import CmuxTerminalBackend
@testable import CmuxTerminalBackendHost
import Foundation
import Testing

@Suite("Backend-only projection planner")
struct BackendOnlyProjectionPlannerTests {
    @Test("selects exact daemon navigation and preserves layout-leaf order")
    func selectsExactNavigationInLayoutLeafOrder() throws {
        let ignoredPane = pane(10, tabs: [surface(10, kind: "terminal")])
        let ignoredScreen = screen(10, panes: [ignoredPane], layout: leaf(ignoredPane))
        let ignoredWorkspace = workspace(10, screens: [ignoredScreen])

        let paneOne = pane(
            21,
            name: "unsupported pane",
            tabs: [surface(211, kind: "markdown", name: "notes")]
        )
        let browserEndpoint = CanonicalBrowserEndpoint(
            transport: .frontendNativeV1,
            source: .launched
        )
        let paneTwo = pane(
            22,
            name: "browser pane",
            tabs: [
                surface(221, kind: "terminal", name: "shell"),
                surface(
                    222,
                    kind: "browser",
                    name: "docs",
                    browserEndpoint: browserEndpoint
                ),
            ]
        )
        let paneThree = pane(
            23,
            name: "pty pane",
            tabs: [surface(231, kind: "pty", name: "remote")]
        )
        let ignoredSelectedWorkspaceScreen = screen(
            20,
            panes: [pane(20, tabs: [surface(201, kind: "terminal")])]
        )
        let selectedScreen = screen(
            21,
            name: "selected screen",
            panes: [paneOne, paneTwo, paneThree],
            layout: .split(
                direction: .right,
                ratio: 0.4,
                first: leaf(paneTwo),
                second: .split(
                    direction: .down,
                    ratio: 0.6,
                    first: leaf(paneOne),
                    second: leaf(paneThree)
                )
            )
        )
        let selectedWorkspace = workspace(
            20,
            name: "selected workspace",
            screens: [ignoredSelectedWorkspaceScreen, selectedScreen]
        )
        let topology = try CanonicalTopology(
            workspaces: [ignoredWorkspace, selectedWorkspace]
        )
        let navigation = BackendOnlyProjectionNavigationInput(
            logicalPresentationID: logicalPresentationID(1),
            selectedWorkspaceID: selectedWorkspace.uuid,
            workspaces: [
                navigationWorkspace(
                    selectedWorkspace,
                    selectedScreenID: selectedScreen.uuid,
                    screens: [
                        navigationScreen(
                            selectedScreen,
                            activePaneID: paneOne.uuid,
                            panes: [
                                navigationPane(paneThree, selectedTab: 0),
                                navigationPane(paneTwo, selectedTab: 1),
                                navigationPane(paneOne, selectedTab: 0),
                            ]
                        ),
                        navigationScreen(ignoredSelectedWorkspaceScreen),
                    ]
                ),
                navigationWorkspace(ignoredWorkspace),
            ]
        )

        let plan = try BackendOnlyProjectionPlanner().plan(
            topology: topology,
            navigation: navigation
        )

        #expect(plan.logicalPresentationID == navigation.logicalPresentationID)
        #expect(plan.workspaceID == selectedWorkspace.uuid)
        #expect(plan.numericWorkspaceID == selectedWorkspace.id)
        #expect(plan.workspaceName == "selected workspace")
        #expect(plan.screenID == selectedScreen.uuid)
        #expect(plan.numericScreenID == selectedScreen.id)
        #expect(plan.screenName == "selected screen")
        #expect(plan.activePaneID == paneOne.uuid)
        #expect(plan.zoomedPaneID == nil)
        #expect(plan.panes.map(\.paneID) == [paneTwo.uuid, paneOne.uuid, paneThree.uuid])

        let paneTwoPlan = try #require(plan.panes.first)
        #expect(paneTwoPlan.numericPaneID == paneTwo.id)
        #expect(paneTwoPlan.paneName == "browser pane")
        #expect(paneTwoPlan.isActive == false)
        #expect(paneTwoPlan.tabs.map(\.surfaceID) == paneTwo.tabs.map(\.uuid))
        #expect(paneTwoPlan.tabs.map(\.isSelected) == [false, true])
        #expect(paneTwoPlan.tabs[1].browserEndpoint == browserEndpoint)
        #expect(
            paneTwoPlan.content == .browserPlaceholder(
                surfaceID: paneTwo.tabs[1].uuid,
                numericSurfaceID: paneTwo.tabs[1].id,
                endpoint: browserEndpoint
            )
        )

        #expect(
            plan.panes[1].content == .unsupportedPlaceholder(
                surfaceID: paneOne.tabs[0].uuid,
                numericSurfaceID: paneOne.tabs[0].id,
                kind: "markdown"
            )
        )
        #expect(
            plan.panes[2].content == .terminal(
                BackendOnlyTerminalSelection(
                    workspaceID: selectedWorkspace.uuid,
                    screenID: selectedScreen.uuid,
                    paneID: paneThree.uuid,
                    surfaceID: paneThree.tabs[0].uuid,
                    numericSurfaceID: paneThree.tabs[0].id
                )
            )
        )

        let paneTwoSlot = slot(
            logicalPresentationID: navigation.logicalPresentationID,
            workspace: selectedWorkspace,
            screen: selectedScreen,
            pane: paneTwo
        )
        let paneOneSlot = slot(
            logicalPresentationID: navigation.logicalPresentationID,
            workspace: selectedWorkspace,
            screen: selectedScreen,
            pane: paneOne
        )
        let paneThreeSlot = slot(
            logicalPresentationID: navigation.logicalPresentationID,
            workspace: selectedWorkspace,
            screen: selectedScreen,
            pane: paneThree
        )
        #expect(
            plan.layout == .split(
                direction: .right,
                ratio: 0.4,
                first: .pane(paneTwoSlot),
                second: .split(
                    direction: .down,
                    ratio: 0.6,
                    first: .pane(paneOneSlot),
                    second: .pane(paneThreeSlot)
                )
            )
        )
    }

    @Test("slot identity excludes the selected surface")
    func slotIdentitySurvivesTabSelectionChanges() throws {
        let terminal = surface(301, kind: "terminal")
        let browser = surface(302, kind: "browser")
        let onlyPane = pane(30, tabs: [terminal, browser])
        let onlyScreen = screen(30, panes: [onlyPane])
        let onlyWorkspace = workspace(30, screens: [onlyScreen])
        let topology = try CanonicalTopology(workspaces: [onlyWorkspace])
        let planner = BackendOnlyProjectionPlanner()

        let terminalPlan = try planner.plan(
            topology: topology,
            navigation: navigation(
                logicalPresentationID: logicalPresentationID(2),
                workspace: onlyWorkspace,
                screen: onlyScreen,
                paneSelections: [(onlyPane, terminal.uuid)]
            )
        )
        let browserPlan = try planner.plan(
            topology: topology,
            navigation: navigation(
                logicalPresentationID: logicalPresentationID(2),
                workspace: onlyWorkspace,
                screen: onlyScreen,
                paneSelections: [(onlyPane, browser.uuid)]
            )
        )

        let terminalDescriptor = try #require(terminalPlan.panes.first)
        let browserDescriptor = try #require(browserPlan.panes.first)
        #expect(terminalDescriptor.slotID == browserDescriptor.slotID)
        #expect(terminalDescriptor.content != browserDescriptor.content)
    }

    @Test("zoom materializes exactly the active pane")
    func zoomMaterializesOnlyTheActiveLeaf() throws {
        let panes = (40 ... 42).map { index in
            pane(UInt64(index), tabs: [surface(UInt64(index * 10), kind: "terminal")])
        }
        let selectedScreen = screen(
            40,
            panes: panes,
            layout: .split(
                direction: .right,
                ratio: 0.5,
                first: leaf(panes[0]),
                second: .split(
                    direction: .down,
                    ratio: 0.5,
                    first: leaf(panes[1]),
                    second: leaf(panes[2])
                )
            )
        )
        let selectedWorkspace = workspace(40, screens: [selectedScreen])
        let topology = try CanonicalTopology(workspaces: [selectedWorkspace])
        let input = BackendOnlyProjectionNavigationInput(
            logicalPresentationID: logicalPresentationID(3),
            selectedWorkspaceID: selectedWorkspace.uuid,
            workspaces: [
                navigationWorkspace(
                    selectedWorkspace,
                    screens: [
                        navigationScreen(
                            selectedScreen,
                            activePaneID: panes[1].uuid,
                            zoomedPaneID: panes[1].uuid
                        ),
                    ]
                ),
            ]
        )

        let plan = try BackendOnlyProjectionPlanner().plan(
            topology: topology,
            navigation: input
        )

        let descriptor = try #require(plan.panes.first)
        #expect(plan.panes.count == 1)
        #expect(descriptor.paneID == panes[1].uuid)
        #expect(descriptor.isActive)
        #expect(plan.layout == .pane(descriptor.slotID))
        #expect(plan.activePaneID == panes[1].uuid)
        #expect(plan.zoomedPaneID == panes[1].uuid)
        #expect(plan.metrics.visibleLeafCount == 1)
        #expect(plan.metrics.visibleLeafCountNodeVisits == 1)
        #expect(plan.metrics.materializedLayoutNodeVisits == 1)
    }

    @Test("invalid navigation fails instead of selecting a fallback")
    func invalidNavigationNeverFallsBack() throws {
        let onlyPane = pane(
            50,
            tabs: [
                surface(501, kind: "terminal"),
                surface(502, kind: "pty"),
            ]
        )
        let onlyScreen = screen(50, panes: [onlyPane])
        let onlyWorkspace = workspace(50, screens: [onlyScreen])
        let topology = try CanonicalTopology(workspaces: [onlyWorkspace])
        let planner = BackendOnlyProjectionPlanner()

        let noWorkspace = BackendOnlyProjectionNavigationInput(
            logicalPresentationID: logicalPresentationID(4),
            selectedWorkspaceID: nil,
            workspaces: [navigationWorkspace(onlyWorkspace)]
        )
        #expect(throws: BackendOnlyProjectionPlannerError.selectedWorkspaceRequired) {
            try planner.plan(topology: topology, navigation: noWorkspace)
        }

        let missingScreenID = ScreenID(rawValue: stableUUID(namespace: 0x2000_0000, value: 999))
        let missingScreen = BackendOnlyProjectionNavigationInput(
            logicalPresentationID: logicalPresentationID(4),
            selectedWorkspaceID: onlyWorkspace.uuid,
            workspaces: [
                BackendOnlyProjectionWorkspaceNavigation(
                    workspaceID: onlyWorkspace.uuid,
                    selectedScreenID: missingScreenID,
                    screens: [navigationScreen(onlyScreen)]
                ),
            ]
        )
        #expect(
            throws: BackendOnlyProjectionPlannerError.selectedScreenMissing(
                workspaceID: onlyWorkspace.uuid,
                screenID: missingScreenID
            )
        ) {
            try planner.plan(topology: topology, navigation: missingScreen)
        }

        let missingSurfaceID = SurfaceID(
            rawValue: stableUUID(namespace: 0x4000_0000, value: 999)
        )
        let missingSurface = navigation(
            logicalPresentationID: logicalPresentationID(4),
            workspace: onlyWorkspace,
            screen: onlyScreen,
            paneSelections: [(onlyPane, missingSurfaceID)]
        )
        #expect(
            throws: BackendOnlyProjectionPlannerError.selectedSurfaceMissing(
                paneID: onlyPane.uuid,
                surfaceID: missingSurfaceID
            )
        ) {
            try planner.plan(topology: topology, navigation: missingSurface)
        }
    }

    @Test("layout depth 128 remains valid")
    func acceptsMaximumCanonicalLayoutDepth() throws {
        let panes = (1 ... CanonicalLayout.maximumDepth).map { index in
            pane(
                UInt64(1_000 + index),
                tabs: [surface(UInt64(10_000 + index), kind: "terminal")]
            )
        }
        var layout = leaf(panes[0])
        for pane in panes.dropFirst() {
            layout = .split(
                direction: .right,
                ratio: 0.5,
                first: leaf(pane),
                second: layout
            )
        }
        let selectedScreen = screen(60, panes: panes, layout: layout)
        let selectedWorkspace = workspace(60, screens: [selectedScreen])
        let topology = try CanonicalTopology(workspaces: [selectedWorkspace])

        let plan = try BackendOnlyProjectionPlanner().plan(
            topology: topology,
            navigation: navigation(
                logicalPresentationID: logicalPresentationID(5),
                workspace: selectedWorkspace,
                screen: selectedScreen,
                paneSelections: panes.map { ($0, $0.tabs[0].uuid) }
            )
        )

        #expect(plan.panes.count == CanonicalLayout.maximumDepth)
        #expect(plan.metrics.visibleLeafCount == CanonicalLayout.maximumDepth)
        #expect(
            plan.metrics.visibleLeafCountNodeVisits
                == (CanonicalLayout.maximumDepth * 2) - 1
        )
        #expect(
            plan.metrics.materializedLayoutNodeVisits
                == (CanonicalLayout.maximumDepth * 2) - 1
        )
    }

    @Test("1000 workspaces and 256 leaves stay linear")
    func indexesScaleFixtureOnceAndAccepts256Leaves() throws {
        var workspaces: [CanonicalWorkspace] = []
        workspaces.reserveCapacity(1_000)
        for index in 1 ..< 1_000 {
            let onlyPane = pane(
                UInt64(20_000 + index),
                tabs: [surface(UInt64(30_000 + index), kind: "terminal")]
            )
            workspaces.append(
                workspace(
                    UInt64(20_000 + index),
                    screens: [
                        screen(UInt64(20_000 + index), panes: [onlyPane]),
                    ]
                )
            )
        }
        let selectedPanes = (0 ..< 256).map { index in
            pane(
                UInt64(40_000 + index),
                tabs: [surface(UInt64(50_000 + index), kind: "terminal")]
            )
        }
        let selectedScreen = screen(
            40_000,
            panes: selectedPanes,
            layout: balancedLayout(selectedPanes[...])
        )
        let selectedWorkspace = workspace(40_000, screens: [selectedScreen])
        workspaces.append(selectedWorkspace)
        let topology = try CanonicalTopology(workspaces: workspaces)
        let navigationWorkspaces = workspaces.reversed().map { navigationWorkspace($0) }
        let input = BackendOnlyProjectionNavigationInput(
            logicalPresentationID: logicalPresentationID(6),
            selectedWorkspaceID: selectedWorkspace.uuid,
            workspaces: navigationWorkspaces
        )

        let plan = try BackendOnlyProjectionPlanner().plan(
            topology: topology,
            navigation: input
        )

        #expect(plan.panes.count == 256)
        #expect(plan.metrics.visibleLeafCount == 256)
        #expect(plan.metrics.topologyWorkspaceIndexVisits == 1_000)
        #expect(plan.metrics.navigationWorkspaceIndexVisits == 1_000)
        #expect(plan.metrics.selectedWorkspaceScreenIndexVisits == 1)
        #expect(plan.metrics.selectedNavigationScreenIndexVisits == 1)
        #expect(plan.metrics.selectedScreenPaneIndexVisits == 256)
        #expect(plan.metrics.selectedNavigationPaneIndexVisits == 256)
        #expect(plan.metrics.visibleLeafCountNodeVisits == 511)
        #expect(plan.metrics.materializedLayoutNodeVisits == 511)
        #expect(plan.metrics.tabMetadataVisits == 256)
    }

    @Test("257 visible leaves fail before a plan is returned")
    func rejects257LeavesAtomically() throws {
        let panes = (0 ..< 257).map { index in
            pane(
                UInt64(60_000 + index),
                tabs: [surface(UInt64(70_000 + index), kind: "terminal")]
            )
        }
        let selectedScreen = screen(
            60_000,
            panes: panes,
            layout: balancedLayout(panes[...])
        )
        let selectedWorkspace = workspace(60_000, screens: [selectedScreen])
        let topology = try CanonicalTopology(workspaces: [selectedWorkspace])
        let input = navigation(
            logicalPresentationID: logicalPresentationID(7),
            workspace: selectedWorkspace,
            screen: selectedScreen,
            paneSelections: panes.map { ($0, $0.tabs[0].uuid) }
        )

        do {
            _ = try BackendOnlyProjectionPlanner().plan(
                topology: topology,
                navigation: input
            )
            Issue.record("planner returned a partial or over-budget plan")
        } catch let error as BackendOnlyProjectionPlannerError {
            #expect(
                error == .visibleLeafLimitExceeded(
                    actual: 257,
                    maximum: BackendOnlyProjectionPlanner.maximumVisibleLeafCount
                )
            )
        }
    }

    private func navigation(
        logicalPresentationID: UUID,
        workspace: CanonicalWorkspace,
        screen: CanonicalScreen,
        paneSelections: [(CanonicalPane, SurfaceID)]
    ) -> BackendOnlyProjectionNavigationInput {
        BackendOnlyProjectionNavigationInput(
            logicalPresentationID: logicalPresentationID,
            selectedWorkspaceID: workspace.uuid,
            workspaces: [
                BackendOnlyProjectionWorkspaceNavigation(
                    workspaceID: workspace.uuid,
                    selectedScreenID: screen.uuid,
                    screens: [
                        BackendOnlyProjectionScreenNavigation(
                            screenID: screen.uuid,
                            activePaneID: paneSelections[0].0.uuid,
                            zoomedPaneID: nil,
                            panes: paneSelections.map { selection in
                                let (pane, selectedSurfaceID) = selection
                                return BackendOnlyProjectionPaneNavigation(
                                    paneID: pane.uuid,
                                    selectedSurfaceID: selectedSurfaceID
                                )
                            }
                        ),
                    ]
                ),
            ]
        )
    }

    private func navigationWorkspace(
        _ workspace: CanonicalWorkspace
    ) -> BackendOnlyProjectionWorkspaceNavigation {
        navigationWorkspace(
            workspace,
            selectedScreenID: workspace.screens[0].uuid,
            screens: workspace.screens.map { navigationScreen($0) }
        )
    }

    private func navigationWorkspace(
        _ workspace: CanonicalWorkspace,
        selectedScreenID: ScreenID? = nil,
        screens: [BackendOnlyProjectionScreenNavigation]
    ) -> BackendOnlyProjectionWorkspaceNavigation {
        BackendOnlyProjectionWorkspaceNavigation(
            workspaceID: workspace.uuid,
            selectedScreenID: selectedScreenID ?? workspace.screens[0].uuid,
            screens: screens
        )
    }

    private func navigationScreen(
        _ screen: CanonicalScreen,
        activePaneID: PaneID? = nil,
        zoomedPaneID: PaneID? = nil,
        panes: [BackendOnlyProjectionPaneNavigation]? = nil
    ) -> BackendOnlyProjectionScreenNavigation {
        BackendOnlyProjectionScreenNavigation(
            screenID: screen.uuid,
            activePaneID: activePaneID ?? screen.panes[0].uuid,
            zoomedPaneID: zoomedPaneID,
            panes: panes ?? screen.panes.map { navigationPane($0, selectedTab: 0) }
        )
    }

    private func navigationPane(
        _ pane: CanonicalPane,
        selectedTab: Int
    ) -> BackendOnlyProjectionPaneNavigation {
        BackendOnlyProjectionPaneNavigation(
            paneID: pane.uuid,
            selectedSurfaceID: pane.tabs[selectedTab].uuid
        )
    }

    private func workspace(
        _ id: UInt64,
        name: String? = nil,
        screens: [CanonicalScreen]
    ) -> CanonicalWorkspace {
        CanonicalWorkspace(
            id: id,
            uuid: WorkspaceID(rawValue: stableUUID(namespace: 0x1000_0000, value: id)),
            name: name ?? "workspace \(id)",
            screens: screens
        )
    }

    private func screen(
        _ id: UInt64,
        name: String? = nil,
        panes: [CanonicalPane],
        layout: CanonicalLayout? = nil
    ) -> CanonicalScreen {
        CanonicalScreen(
            id: id,
            uuid: ScreenID(rawValue: stableUUID(namespace: 0x2000_0000, value: id)),
            name: name,
            layout: layout ?? balancedLayout(panes[...]),
            panes: panes
        )
    }

    private func pane(
        _ id: UInt64,
        name: String? = nil,
        tabs: [CanonicalSurface]
    ) -> CanonicalPane {
        CanonicalPane(
            id: id,
            uuid: PaneID(rawValue: stableUUID(namespace: 0x3000_0000, value: id)),
            name: name,
            tabs: tabs
        )
    }

    private func surface(
        _ id: UInt64,
        kind: String,
        name: String? = nil,
        browserEndpoint: CanonicalBrowserEndpoint? = nil
    ) -> CanonicalSurface {
        CanonicalSurface(
            id: id,
            uuid: SurfaceID(rawValue: stableUUID(namespace: 0x4000_0000, value: id)),
            kind: kind,
            name: name,
            browserEndpoint: browserEndpoint
        )
    }

    private func leaf(_ pane: CanonicalPane) -> CanonicalLayout {
        .leaf(pane: pane.id, paneUUID: pane.uuid)
    }

    private func balancedLayout(
        _ panes: ArraySlice<CanonicalPane>
    ) -> CanonicalLayout {
        precondition(!panes.isEmpty)
        guard panes.count > 1 else {
            return leaf(panes[panes.startIndex])
        }
        let midpoint = panes.index(panes.startIndex, offsetBy: panes.count / 2)
        return .split(
            direction: .right,
            ratio: 0.5,
            first: balancedLayout(panes[..<midpoint]),
            second: balancedLayout(panes[midpoint...])
        )
    }

    private func slot(
        logicalPresentationID: UUID,
        workspace: CanonicalWorkspace,
        screen: CanonicalScreen,
        pane: CanonicalPane
    ) -> BackendOnlyProjectionSlotID {
        BackendOnlyProjectionSlotID(
            logicalPresentationID: logicalPresentationID,
            workspaceID: workspace.uuid,
            screenID: screen.uuid,
            paneID: pane.uuid
        )
    }

    private func logicalPresentationID(_ value: UInt64) -> UUID {
        stableUUID(namespace: 0x5000_0000, value: value)
    }

    private func stableUUID(namespace: UInt32, value: UInt64) -> UUID {
        let text = String(
            format: "%08x-0000-0000-0000-%012llx",
            namespace,
            value
        )
        guard let uuid = UUID(uuidString: text) else {
            preconditionFailure("invalid deterministic UUID fixture")
        }
        return uuid
    }
}
