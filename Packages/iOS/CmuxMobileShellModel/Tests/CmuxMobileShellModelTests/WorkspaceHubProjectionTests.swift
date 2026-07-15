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

    @Test func portraitCanvasRestacksWideSplitsAndPreservesOrderAndRatios() throws {
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
                    ratio: 0.5,
                    first: paneNode(id: "top-right", tabID: "surface-top"),
                    second: paneNode(id: "bottom-right", tabID: "surface-bottom")
                ))
            )),
            activePaneID: "left"
        )

        // A phone-shaped canvas (half as wide as tall): the root's side-by-side
        // split re-stacks vertically with the Mac's 0.4 ratio, so the Mac's
        // left pane becomes the top band. The inner cell (full width 0.5,
        // height 0.6 => rendered aspect 0.5/0.6 < 1) stays a vertical stack.
        let projection = WorkspaceHubProjection(
            layout: layout,
            fallbackTerminals: [],
            supportsLayout: true,
            canvasAspect: 0.5
        )

        #expect(projection.panes.map(\.id) == ["left", "top-right", "bottom-right"])
        #expect(projection.panes[0].frame == WorkspaceHubPaneFrame(x: 0, y: 0, width: 1, height: 0.4))
        #expect(projection.panes[1].frame == WorkspaceHubPaneFrame(x: 0, y: 0.4, width: 1, height: 0.3))
        #expect(projection.panes[2].frame == WorkspaceHubPaneFrame(x: 0, y: 0.7, width: 1, height: 0.3))
        #expect(projection.panes[0].focusState == .focused)
    }

    @Test func wideCellOnPortraitCanvasStillSplitsSideBySide() throws {
        // A cell rendered wider than tall keeps children side by side even on a
        // portrait canvas: a squat top band (height 0.2 of a 0.8-aspect canvas
        // => rendered 0.8 wide x 0.2 tall) must not stack into slivers.
        let layout = MobileWorkspaceLayout(
            workspaceID: "workspace",
            root: .split(MobileWorkspaceSplit(
                id: "root",
                orientation: .vertical,
                ratio: 0.2,
                first: .split(MobileWorkspaceSplit(
                    id: "band",
                    orientation: .horizontal,
                    ratio: 0.5,
                    first: paneNode(id: "band-left", tabID: "s1"),
                    second: paneNode(id: "band-right", tabID: "s2")
                )),
                second: paneNode(id: "main", tabID: "s3")
            )),
            activePaneID: "main"
        )

        let projection = WorkspaceHubProjection(
            layout: layout,
            fallbackTerminals: [],
            supportsLayout: true,
            canvasAspect: 0.8
        )

        #expect(projection.panes.map(\.id) == ["band-left", "band-right", "main"])
        #expect(projection.panes[0].frame == WorkspaceHubPaneFrame(x: 0, y: 0, width: 0.5, height: 0.2))
        #expect(projection.panes[1].frame == WorkspaceHubPaneFrame(x: 0.5, y: 0, width: 0.5, height: 0.2))
        #expect(projection.panes[2].frame == WorkspaceHubPaneFrame(x: 0, y: 0.2, width: 1, height: 0.8))
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

    @Test func projectsBrowserKindAndMostUrgentBoundChatPresence() throws {
        let layout = MobileWorkspaceLayout(
            workspaceID: "workspace",
            root: .pane(MobileWorkspacePane(
                id: "pane",
                frame: .unit,
                tabs: [
                    MobileWorkspaceTab(
                        id: "browser",
                        name: "Docs",
                        kind: .browser,
                        isActive: true,
                        isReady: true
                    ),
                    MobileWorkspaceTab(
                        id: "terminal",
                        name: "Agent",
                        kind: .terminal,
                        isActive: false,
                        isReady: true
                    ),
                ]
            )),
            activePaneID: "pane"
        )
        let projection = WorkspaceHubProjection(
            layout: layout,
            fallbackTerminals: [],
            supportsLayout: true,
            chatCards: [
                PaneChatCardSnapshot(
                    id: "chat",
                    terminalID: "terminal",
                    title: "Agent",
                    agentStatus: .needsInput
                ),
            ]
        )
        let pane = try #require(projection.panes.only)
        #expect(pane.activeKind == .browser)
        #expect(pane.chatAgentStatus == .needsInput)
        #expect(WorkspaceHubPreviewDemand(panes: [pane], visiblePaneIDs: ["pane"]).surfaceIDs.isEmpty)
    }

    @Test func ignoresUnboundChatsAndKeepsUrgencyPerPane() throws {
        let layout = MobileWorkspaceLayout(
            workspaceID: "workspace",
            root: .split(MobileWorkspaceSplit(
                id: "split",
                orientation: .horizontal,
                ratio: 0.5,
                first: paneNode(id: "left", tabID: "left-terminal"),
                second: paneNode(id: "right", tabID: "right-terminal")
            )),
            activePaneID: "left"
        )
        let chats = (0..<100).map { index in
            PaneChatCardSnapshot(
                id: "unbound-\(index)",
                terminalID: "other-\(index)",
                title: "Other",
                agentStatus: .needsInput
            )
        } + [
            PaneChatCardSnapshot(
                id: "left-chat",
                terminalID: "left-terminal",
                title: "Left",
                agentStatus: .running
            ),
        ]
        let projection = WorkspaceHubProjection(
            layout: layout,
            fallbackTerminals: [],
            supportsLayout: true,
            chatCards: chats
        )

        #expect(try #require(projection.panes.first { $0.id == "left" }).chatAgentStatus == .running)
        #expect(try #require(projection.panes.first { $0.id == "right" }).chatAgentStatus == nil)
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
