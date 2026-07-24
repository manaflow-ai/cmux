import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Suite struct SurfaceDeckValueTests {
    @Test func deckRemainsVisibleForCreationActionsWithZeroOrOneTerminal() {
        let noTerminals = MobileWorkspacePreview(
            id: "empty-workspace",
            name: "Empty Workspace",
            terminals: []
        )
        let emptyValue = value(workspace: noTerminals, selectedSurfaceID: nil)

        let oneTerminal = MobileWorkspacePreview(
            id: "workspace",
            name: "Workspace",
            terminals: [MobileTerminalPreview(id: "terminal-1", name: "Build")]
        )
        let oneValue = value(workspace: oneTerminal, selectedSurfaceID: "terminal-1")

        #expect(emptyValue.groups.count == 1)
        #expect(emptyValue.groups[0].chips.isEmpty)
        #expect(emptyValue.shouldShow)
        #expect(oneValue.groups.count == 1)
        #expect(oneValue.groups[0].chips.map(\.id) == ["terminal-1"])
        #expect(oneValue.shouldShow)
    }

    @Test func olderMacUsesOneTerminalGroupAndPreservesSurfaceOrder() {
        let oneTerminal = MobileWorkspacePreview(
            id: "workspace",
            name: "Workspace",
            terminals: [MobileTerminalPreview(id: "terminal-1", name: "Build")]
        )
        let oneValue = value(workspace: oneTerminal, selectedSurfaceID: "terminal-1")

        let twoTerminals = MobileWorkspacePreview(
            id: "workspace",
            name: "Workspace",
            terminals: [
                MobileTerminalPreview(id: "terminal-1", name: "Build"),
                MobileTerminalPreview(id: "terminal-2", name: "Tests"),
            ]
        )
        let twoValue = value(workspace: twoTerminals, selectedSurfaceID: "terminal-2")

        #expect(oneValue.groups.count == 1)
        #expect(oneValue.groups[0].chips.map(\.id) == ["terminal-1"])
        #expect(oneValue.showsPaneMap == false)
        #expect(twoValue.groups[0].chips.map(\.id) == ["terminal-1", "terminal-2"])
        #expect(twoValue.shouldShow)
        #expect(twoValue.selectedSurfaceID == "terminal-2")
    }

    @Test func layoutPreservesPaneAndSurfaceOrderIncludingDisabledSurfaceTypes() {
        let workspace = MobileWorkspacePreview(
            id: "workspace",
            name: "Workspace",
            terminals: [MobileTerminalPreview(id: "terminal-1", name: "Build")],
            layout: MobilePaneLayout(
                version: 3,
                focusedPaneID: "pane-2",
                root: .split(
                    MobilePaneSplit(
                        id: "split",
                        orientation: .horizontal,
                        ratio: 0.5,
                        first: .pane(
                            MobilePaneNode(
                                id: "pane-1",
                                selectedSurfaceID: "terminal-1",
                                surfaces: [
                                    MobilePaneSurface(id: "terminal-1", type: .terminal, title: "Build"),
                                    MobilePaneSurface(id: "browser-1", type: .browser, title: "Docs"),
                                ]
                            )
                        ),
                        second: .pane(
                            MobilePaneNode(
                                id: "pane-2",
                                selectedSurfaceID: "markdown-1",
                                surfaces: [
                                    MobilePaneSurface(id: "markdown-1", type: .markdown, title: "Notes")
                                ]
                            )
                        )
                    )
                )
            )
        )

        let deck = value(workspace: workspace, selectedSurfaceID: "terminal-1")

        #expect(deck.groups.map(\.id) == ["pane-1", "pane-2"])
        #expect(deck.groups.map(\.number) == [1, 2])
        #expect(deck.groups.map(\.totalCount) == [2, 2])
        #expect(deck.groups[0].chips.map(\.id) == ["terminal-1", "browser-1"])
        #expect(deck.groups[0].chips[0].isTerminal)
        #expect(deck.groups[0].chips[1].isTerminal == false)
        #expect(deck.groups[1].chips.map(\.title) == ["Notes"])
        #expect(deck.shouldShow)
        #expect(deck.showsPaneMap)
    }

    @Test func valueCarriesPrecomputedAgentStatesWithoutStoreReferences() {
        let workspace = MobileWorkspacePreview(
            id: "workspace",
            name: "Workspace",
            terminals: [
                MobileTerminalPreview(id: "terminal-1", name: "Build"),
                MobileTerminalPreview(id: "terminal-2", name: "Tests"),
            ]
        )

        let deck = SurfaceDeckValue(
            workspace: workspace,
            selectedSurfaceID: "terminal-1",
            agentStateKindsBySurfaceID: [
                "terminal-1": .working,
                "terminal-2": .needsInput,
            ],
            canCreateWorkspace: false
        )

        #expect(deck.agentStateKindsBySurfaceID["terminal-1"] == .working)
        #expect(deck.agentStateKindsBySurfaceID["terminal-2"] == .needsInput)
        #expect(deck.canCreateWorkspace == false)
    }

    @Test func paneMapSelectionReconcilesRemovedSurfacesAndPanes() {
        let layout = MobilePaneLayout(
            version: 4,
            focusedPaneID: "pane-1",
            root: .pane(
                MobilePaneNode(
                    id: "pane-1",
                    selectedSurfaceID: "terminal-new",
                    surfaces: [
                        MobilePaneSurface(id: "terminal-keep", type: .terminal, title: "Keep"),
                        MobilePaneSurface(id: "terminal-new", type: .terminal, title: "New"),
                    ]
                )
            )
        )
        let paneMap = PaneMapValue(
            workspaceName: "Workspace",
            layout: layout,
            phoneSelectedSurfaceID: "terminal-new",
            agentStateKindsBySurfaceID: [:]
        )

        #expect(
            paneMap.reconciledSurfaceIDs(current: [
                "pane-1": "terminal-removed",
                "pane-removed": "terminal-old",
            ]) == ["pane-1": "terminal-new"]
        )
        #expect(
            paneMap.reconciledSurfaceIDs(current: ["pane-1": "terminal-keep"])
                == ["pane-1": "terminal-keep"]
        )
    }

    private func value(
        workspace: MobileWorkspacePreview,
        selectedSurfaceID: String?
    ) -> SurfaceDeckValue {
        SurfaceDeckValue(
            workspace: workspace,
            selectedSurfaceID: selectedSurfaceID,
            agentStateKindsBySurfaceID: [:],
            canCreateWorkspace: true
        )
    }
}
