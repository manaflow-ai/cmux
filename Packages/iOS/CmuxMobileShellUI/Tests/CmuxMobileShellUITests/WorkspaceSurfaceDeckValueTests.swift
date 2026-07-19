import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceSurfaceDeckValueTests {
    @Test func resolvesActivePaneAndPreservesPerPaneTabOrder() {
        let build = MobileTerminalPreview(id: "build", name: "Build")
        let tests = MobileTerminalPreview(id: "tests", name: "Tests")
        let logs = MobileTerminalPreview(id: "logs", name: "Logs")
        let workspace = MobileWorkspacePreview(
            id: "workspace",
            name: "Deck",
            terminals: [build, tests, logs],
            paneLayout: MobileWorkspacePaneLayout(
                root: .split(
                    MobileWorkspaceSplitPreview(
                        id: "split",
                        axis: .horizontal,
                        fraction: 0.4,
                        first: .pane(
                            MobileWorkspacePanePreview(
                                id: "left",
                                terminalIDs: [build.id, tests.id],
                                selectedTerminalID: build.id
                            )
                        ),
                        second: .pane(
                            MobileWorkspacePanePreview(
                                id: "right",
                                terminalIDs: [logs.id],
                                selectedTerminalID: logs.id,
                                isFocused: true
                            )
                        )
                    )
                )
            )
        )

        let value = WorkspaceSurfaceDeckValue(workspace: workspace, selectedTerminalID: tests.id)

        #expect(value.panes.map(\.id.rawValue) == ["left", "right"])
        #expect(value.panes[0].terminals.map(\.id) == [build.id, tests.id])
        #expect(value.activePaneID?.rawValue == "left")
        #expect(value.panes[0].selectedTerminalID == tests.id)
        #expect(value.panes[0].frame.width == 0.4)
        #expect(value.panes[1].frame.x == 0.4)
        #expect(value.panes[1].frame.width == 0.6)
    }

    @Test func nestedSplitProducesExactNormalizedFrames() {
        let terminals = (1...3).map {
            MobileTerminalPreview(id: .init(rawValue: "t\($0)"), name: "T\($0)")
        }
        let workspace = MobileWorkspacePreview(
            id: "workspace",
            name: "Nested",
            terminals: terminals,
            paneLayout: MobileWorkspacePaneLayout(
                root: .split(
                    MobileWorkspaceSplitPreview(
                        id: "root",
                        axis: .horizontal,
                        fraction: 0.6,
                        first: .pane(MobileWorkspacePanePreview(id: "one", terminalIDs: [terminals[0].id])),
                        second: .split(
                            MobileWorkspaceSplitPreview(
                                id: "right",
                                axis: .vertical,
                                fraction: 0.25,
                                first: .pane(MobileWorkspacePanePreview(id: "two", terminalIDs: [terminals[1].id])),
                                second: .pane(MobileWorkspacePanePreview(id: "three", terminalIDs: [terminals[2].id]))
                            )
                        )
                    )
                )
            )
        )

        let value = WorkspaceSurfaceDeckValue(workspace: workspace, selectedTerminalID: terminals[2].id)

        #expect(value.panes[0].frame == .init(x: 0, y: 0, width: 0.6, height: 1))
        #expect(value.panes[1].frame == .init(x: 0.6, y: 0, width: 0.4, height: 0.25))
        #expect(value.panes[2].frame == .init(x: 0.6, y: 0.25, width: 0.4, height: 0.75))
    }

    @Test func remembersThePhonesLastTabInEachPane() {
        let build = MobileTerminalPreview(id: "build", name: "Build")
        let tests = MobileTerminalPreview(id: "tests", name: "Tests")
        let logs = MobileTerminalPreview(id: "logs", name: "Logs")
        let workspace = MobileWorkspacePreview(
            id: "workspace",
            name: "Remembered tabs",
            terminals: [build, tests, logs],
            paneLayout: MobileWorkspacePaneLayout(
                root: .split(
                    MobileWorkspaceSplitPreview(
                        id: "split",
                        axis: .horizontal,
                        fraction: 0.5,
                        first: .pane(
                            MobileWorkspacePanePreview(
                                id: "left",
                                terminalIDs: [build.id, tests.id],
                                selectedTerminalID: build.id
                            )
                        ),
                        second: .pane(
                            MobileWorkspacePanePreview(
                                id: "right",
                                terminalIDs: [logs.id],
                                selectedTerminalID: logs.id
                            )
                        )
                    )
                )
            )
        )

        let value = WorkspaceSurfaceDeckValue(
            workspace: workspace,
            selectedTerminalID: logs.id,
            paneSelections: ["left": tests.id]
        )

        #expect(value.activePaneID?.rawValue == "right")
        #expect(value.panes[0].selectedTerminalID == tests.id)
        #expect(value.panes[1].selectedTerminalID == logs.id)
    }

    @Test func legacyWorkspaceSynthesizesOneUntargetedPane() {
        let terminal = MobileTerminalPreview(id: "terminal", name: "Terminal")
        let workspace = MobileWorkspacePreview(
            id: "workspace",
            name: "Legacy",
            terminals: [terminal]
        )

        let value = WorkspaceSurfaceDeckValue(workspace: workspace, selectedTerminalID: terminal.id)

        #expect(value.panes.count == 1)
        #expect(value.activePane?.remoteID == nil)
        #expect(value.activePane?.terminals == [terminal])
        #expect(value.hasAuthoritativeLayout == false)
    }

    @Test func unreferencedTerminalRemainsReachable() {
        let referenced = MobileTerminalPreview(id: "referenced", name: "Referenced")
        let orphan = MobileTerminalPreview(id: "orphan", name: "Orphan")
        let workspace = MobileWorkspacePreview(
            id: "workspace",
            name: "Mixed",
            terminals: [referenced, orphan],
            paneLayout: MobileWorkspacePaneLayout(
                root: .pane(MobileWorkspacePanePreview(id: "pane", terminalIDs: [referenced.id]))
            )
        )

        let value = WorkspaceSurfaceDeckValue(workspace: workspace, selectedTerminalID: orphan.id)

        #expect(value.panes[0].terminals.map(\.id) == [referenced.id, orphan.id])
        #expect(value.panes[0].selectedTerminalID == orphan.id)
        #expect(value.activePaneID?.rawValue == "pane")
    }
}
