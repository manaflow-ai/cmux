import CMUXMobileCore
import Testing

@testable import CmuxMobileShellModel

@Suite struct WorkspaceHubProjectionTests {
    @Test func laysOutNestedSplitRatios() throws {
        let layout = MobileWorkspaceLayout(
            workspaceID: "workspace",
            root: .split(MobileWorkspaceSplit(
                id: "root",
                orientation: .horizontal,
                ratio: 0.4,
                first: paneNode(id: "left", tabID: "surface-left"),
                second: .split(MobileWorkspaceSplit(
                    id: "right-split",
                    orientation: .vertical,
                    ratio: 0.25,
                    first: paneNode(id: "top-right", tabID: "surface-top"),
                    second: paneNode(id: "bottom-right", tabID: "surface-bottom")
                ))
            )),
            activePaneID: "bottom-right"
        )

        let projection = WorkspaceHubProjection(
            layout: layout,
            fallbackTerminals: [],
            supportsLayout: true
        )

        #expect(projection.panes.map(\.id) == ["left", "top-right", "bottom-right"])
        #expect(projection.panes[0].frame == WorkspaceHubPaneFrame(x: 0, y: 0, width: 0.4, height: 1))
        #expect(projection.panes[1].frame == WorkspaceHubPaneFrame(x: 0.4, y: 0, width: 0.6, height: 0.25))
        #expect(projection.panes[2].frame == WorkspaceHubPaneFrame(x: 0.4, y: 0.25, width: 0.6, height: 0.75))
        #expect(projection.panes[2].focusState == .focused)
    }

    @Test func laysOutDegenerateSinglePaneAtFullSize() throws {
        let projection = WorkspaceHubProjection(
            layout: MobileWorkspaceLayout(
                workspaceID: "workspace",
                root: paneNode(id: "only", tabID: "surface"),
                activePaneID: "only"
            ),
            fallbackTerminals: [],
            supportsLayout: true
        )

        let pane = try #require(projection.panes.only)
        #expect(pane.frame == .unit)
        #expect(pane.focusState == .focused)
        #expect(!projection.isDegraded)
    }

    @Test func mapsLegacyFlatTerminalsToStableFullWidthCards() {
        let terminals = [
            MobileTerminalPreview(id: "one", name: "One", isFocused: false),
            MobileTerminalPreview(id: "two", name: "Two", isFocused: true),
        ]

        let projection = WorkspaceHubProjection(
            layout: nil,
            fallbackTerminals: terminals,
            supportsLayout: false
        )

        #expect(projection.isDegraded)
        #expect(projection.panes.map(\.id) == ["fallback:one", "fallback:two"])
        #expect(projection.panes.map(\.activeSurfaceID) == ["one", "two"])
        #expect(projection.panes.allSatisfy { $0.frame.x == 0 && $0.frame.width == 1 })
        #expect(projection.panes[1].focusState == .focused)
    }

    @Test func usesFallbackWhileCapableMacAwaitsFirstLayoutWithoutDegradedWarning() {
        let projection = WorkspaceHubProjection(
            layout: nil,
            fallbackTerminals: [MobileTerminalPreview(id: "one", name: "One", isFocused: true)],
            supportsLayout: true
        )

        #expect(!projection.isDegraded)
        #expect(projection.panes.map(\.activeSurfaceID) == ["one"])
    }

    @Test func mapsFocusOnlyToAuthoritativeActivePane() {
        #expect(WorkspaceHubFocusState(paneID: "one", activePaneID: "one") == .focused)
        #expect(WorkspaceHubFocusState(paneID: "two", activePaneID: "one") == .unfocused)
        #expect(WorkspaceHubFocusState(paneID: "one", activePaneID: nil) == .unfocused)
    }

    @Test func derivesDemandFromVisibleActiveTabsOnly() {
        let projection = WorkspaceHubProjection(
            layout: MobileWorkspaceLayout(
                workspaceID: "workspace",
                root: .split(MobileWorkspaceSplit(
                    id: "split",
                    orientation: .horizontal,
                    ratio: 0.5,
                    first: paneNode(id: "left", tabID: "surface-left"),
                    second: paneNode(id: "right", tabID: "surface-right")
                )),
                activePaneID: nil
            ),
            fallbackTerminals: [],
            supportsLayout: true
        )

        let demand = WorkspaceHubPreviewDemand(
            panes: projection.panes,
            visiblePaneIDs: ["right", "closed-pane"]
        )

        #expect(demand.surfaceIDs == ["surface-right"])
    }

    private func paneNode(id: String, tabID: String) -> MobileWorkspaceLayoutNode {
        .pane(MobileWorkspacePane(
            id: id,
            frame: .unit,
            tabs: [MobileWorkspaceTab(
                id: tabID,
                name: tabID,
                kind: .terminal,
                isActive: true,
                isReady: true
            )]
        ))
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
