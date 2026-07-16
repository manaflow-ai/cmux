import CmuxWorkspaces
import Foundation

extension MobileWorkspaceHierarchyProjection {
    struct FocusValue: Hashable {
        let schemaVersion: Int
        let workspaceID: UUID
        let focusedPaneID: UUID?
        let selectedTerminalID: UUID?
        let paneSelections: [PaneFocusValue]

        /// Samples only focus dimensions. This is the always-on focus-event hot
        /// path, so it must not touch titles, directories, pin state, or payload
        /// terminal allocation.
        @MainActor
        init(workspace: Workspace) {
            workspaceID = workspace.id
            focusedPaneID = workspace.bonsplitController.focusedPaneId?.id
            selectedTerminalID = workspace.focusedTerminalPanel?.id
            paneSelections = workspace.bonsplitController.allPaneIds.map { paneID in
                let terminalID = workspace.bonsplitController.selectedTab(inPane: paneID)
                    .flatMap { workspace.panelIdFromSurfaceId($0.id) }
                    .flatMap { workspace.terminalPanel(for: $0)?.id }
                return PaneFocusValue(id: paneID.id, selectedTerminalID: terminalID)
            }
            schemaVersion = MobileWorkspaceHierarchyProjection.schemaVersion
        }

        func eventPayload(sequence: UInt64) -> [String: Any] {
            [
                "kind": "focus",
                "workspace_id": workspaceID.uuidString,
                "focused_pane_id": focusedPaneID?.uuidString ?? NSNull(),
                "selected_terminal_id": selectedTerminalID?.uuidString ?? NSNull(),
                "seq": sequence,
            ]
        }
    }
}
