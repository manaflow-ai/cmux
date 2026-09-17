import CmuxTerminalBackend
@testable import CmuxTerminalBackendHost
import Foundation
import Testing

struct BackendOnlyTopologyTests {
    @Test
    func firstTerminalSkipsFrontendNativeSurfacesAndPreservesCanonicalOrder() throws {
        let workspaceID = WorkspaceID(rawValue: try #require(UUID(
            uuidString: "10000000-0000-0000-0000-000000000001"
        )))
        let screenID = ScreenID(rawValue: try #require(UUID(
            uuidString: "20000000-0000-0000-0000-000000000001"
        )))
        let paneID = PaneID(rawValue: try #require(UUID(
            uuidString: "30000000-0000-0000-0000-000000000001"
        )))
        let browserID = SurfaceID(rawValue: try #require(UUID(
            uuidString: "40000000-0000-0000-0000-000000000001"
        )))
        let terminalID = SurfaceID(rawValue: try #require(UUID(
            uuidString: "40000000-0000-0000-0000-000000000002"
        )))
        let laterTerminalID = SurfaceID(rawValue: try #require(UUID(
            uuidString: "40000000-0000-0000-0000-000000000003"
        )))
        let workspace = CanonicalWorkspace(
            id: 1,
            uuid: workspaceID,
            name: "workspace",
            screens: [
                CanonicalScreen(
                    id: 2,
                    uuid: screenID,
                    name: nil,
                    layout: .leaf(pane: 3, paneUUID: paneID),
                    panes: [
                        CanonicalPane(
                            id: 3,
                            uuid: paneID,
                            name: nil,
                            tabs: [
                                CanonicalSurface(
                                    id: 4,
                                    uuid: browserID,
                                    kind: "browser",
                                    name: nil
                                ),
                                CanonicalSurface(
                                    id: 5,
                                    uuid: terminalID,
                                    kind: "terminal",
                                    name: nil
                                ),
                                CanonicalSurface(
                                    id: 6,
                                    uuid: laterTerminalID,
                                    kind: "terminal",
                                    name: nil
                                ),
                            ]
                        ),
                    ]
                ),
            ]
        )

        #expect(workspace.backendOnlyFirstTerminal == BackendOnlyTerminalSelection(
            workspaceID: workspaceID,
            screenID: screenID,
            paneID: paneID,
            surfaceID: terminalID,
            numericSurfaceID: 5
        ))
    }

    @Test
    func workspaceWithoutTerminalHasNoRendererSelection() throws {
        let workspaceID = WorkspaceID(rawValue: try #require(UUID(
            uuidString: "10000000-0000-0000-0000-000000000002"
        )))
        let screenID = ScreenID(rawValue: try #require(UUID(
            uuidString: "20000000-0000-0000-0000-000000000002"
        )))
        let paneID = PaneID(rawValue: try #require(UUID(
            uuidString: "30000000-0000-0000-0000-000000000002"
        )))
        let browserID = SurfaceID(rawValue: try #require(UUID(
            uuidString: "40000000-0000-0000-0000-000000000004"
        )))
        let workspace = CanonicalWorkspace(
            id: 1,
            uuid: workspaceID,
            name: "workspace",
            screens: [
                CanonicalScreen(
                    id: 2,
                    uuid: screenID,
                    name: nil,
                    layout: .leaf(pane: 3, paneUUID: paneID),
                    panes: [
                        CanonicalPane(
                            id: 3,
                            uuid: paneID,
                            name: nil,
                            tabs: [
                                CanonicalSurface(
                                    id: 4,
                                    uuid: browserID,
                                    kind: "browser",
                                    name: nil
                                ),
                            ]
                        ),
                    ]
                ),
            ]
        )

        #expect(workspace.backendOnlyFirstTerminal == nil)
    }
}
