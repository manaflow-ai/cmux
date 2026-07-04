import Foundation

/// JSON-serializable snapshot of the Mac focus target for mobile Voice Mode.
struct MobileFocusSnapshotPayload: Equatable {
    let workspaceID: UUID?
    let workspaceTitle: String?
    let surfaceID: UUID?
    let surfaceTitle: String?
    let surfaceType: String?
    let isTerminal: Bool

    /// Builds the focus snapshot for a tab manager's selected workspace.
    /// - Parameter tabManager: The tab manager whose current focus should be projected.
    /// - Returns: A snapshot for the selected workspace and focused panel.
    @MainActor
    static func snapshot(tabManager: TabManager) -> MobileFocusSnapshotPayload {
        guard let workspaceID = tabManager.selectedTabId,
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
            return MobileFocusSnapshotPayload(
                workspaceID: nil,
                workspaceTitle: nil,
                surfaceID: nil,
                surfaceTitle: nil,
                surfaceType: nil,
                isTerminal: false
            )
        }
        guard let surfaceID = workspace.focusedPanelId else {
            return MobileFocusSnapshotPayload(
                workspaceID: workspace.id,
                workspaceTitle: workspace.title,
                surfaceID: nil,
                surfaceTitle: nil,
                surfaceType: nil,
                isTerminal: false
            )
        }
        return MobileFocusSnapshotPayload(
            workspaceID: workspace.id,
            workspaceTitle: workspace.title,
            surfaceID: surfaceID,
            surfaceTitle: workspace.panelTitle(panelId: surfaceID),
            surfaceType: workspace.panelKind(panelId: surfaceID),
            isTerminal: workspace.terminalPanel(for: surfaceID) != nil
        )
    }

    /// Hash of fields that should trigger a focus update.
    var summaryHash: Int {
        var hasher = Hasher()
        hasher.combine(workspaceID)
        hasher.combine(workspaceTitle)
        hasher.combine(surfaceID)
        hasher.combine(surfaceTitle)
        hasher.combine(surfaceType)
        hasher.combine(isTerminal)
        return hasher.finalize()
    }

    /// Converts the snapshot to the mobile JSON payload shape.
    /// - Parameter controller: The handle-ref source for workspace/surface refs.
    /// - Returns: A JSON object with nullable focus fields.
    @MainActor
    func jsonObject(controller: TerminalController = .shared) -> [String: Any] {
        [
            "workspace_id": workspaceID?.uuidString as Any? ?? NSNull(),
            "workspace_ref": controller.v2Ref(kind: .workspace, uuid: workspaceID),
            "workspace_title": workspaceTitle as Any? ?? NSNull(),
            "surface_id": surfaceID?.uuidString as Any? ?? NSNull(),
            "surface_ref": controller.v2Ref(kind: .surface, uuid: surfaceID),
            "surface_title": surfaceTitle as Any? ?? NSNull(),
            "surface_type": surfaceType as Any? ?? NSNull(),
            "is_terminal": isTerminal,
        ]
    }
}
