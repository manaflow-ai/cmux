import Bonsplit
import CmuxCore
import CmuxSurfaceCatalogModel
import Foundation

extension Workspace {
    /// Captures split geometry and stable panel IDs for Mac workspace-layout requests.
    func deviceWorkspaceLayoutSnapshot() -> DeviceWorkspaceLayoutNode? {
        deviceLayoutNode(bonsplitController.treeSnapshot())
    }

    private func deviceLayoutNode(_ node: ExternalTreeNode) -> DeviceWorkspaceLayoutNode? {
        switch node {
        case .pane(let pane):
            return .pane(
                id: pane.id,
                surfaceIDs: pane.tabs.compactMap { deviceLayoutPanelID($0.id) },
                selectedSurfaceID: pane.selectedTabId.flatMap { deviceLayoutPanelID($0) }
            )
        case .split(let split):
            guard let direction = DeviceWorkspaceLayoutNode.Direction(rawValue: split.orientation),
                  split.dividerPosition.isFinite,
                  let first = deviceLayoutNode(split.first),
                  let second = deviceLayoutNode(split.second) else { return nil }
            return .split(direction: direction, ratio: split.dividerPosition, first: first, second: second)
        }
    }

    private func deviceLayoutPanelID(_ tabID: String) -> String? {
        guard let id = UUID(uuidString: tabID) else { return nil }
        return panelIdFromSurfaceId(TabID(uuid: id))?.uuidString
    }

    /// Applies only geometry and tab ordering; native terminal objects stay alive.
    func applyDeviceWorkspaceLayout(_ layout: DeviceWorkspaceLayoutNode) throws {
        let ids = try layout.validatedSurfaceIDs()
        guard !isRemoteTmuxMirror, Set(ids) == Set(panels.keys.map(\.uuidString)),
              let previous = deviceWorkspaceLayoutSnapshot() else {
            throw DeviceWorkspaceLayoutValidationError.unmappedSurface
        }
        let projections = try ids.map { raw -> SurfaceProjection in
            guard let panelID = UUID(uuidString: raw), surfaceIdFromPanelId(panelID) != nil else {
                throw DeviceWorkspaceLayoutValidationError.unmappedSurface
            }
            // These local identities are used only by the native geometry
            // applicator. They never enter the catalog or create an attachment.
            return SurfaceProjection(resource: SurfaceResourceID(machine: .local, kind: .terminal, key: raw),
                workspaceID: id, panelID: panelID, remoteWorkspaceID: id.uuidString, remoteTabID: raw)
        }
        let placements = Dictionary(uniqueKeysWithValues: projections.map { projection in
            (projection.resource.key, SurfaceResourcePlacement(resource: projection.resource,
                remoteWorkspaceID: projection.remoteWorkspaceID, remoteTabID: projection.remoteTabID))
        })
        let translator = DeviceWorkspaceProjection(machine: .local, isLive: true)
        guard let translated = translator.translate(layout, placements: placements) else {
            throw DeviceWorkspaceLayoutValidationError.unmappedSurface
        }
        applyCloudWorkspaceLayout(translated, projections: projections)
        guard deviceWorkspaceLayoutSnapshot()?.hasSameArrangement(as: layout) == true else {
            if let rollback = translator.translate(previous, placements: placements) {
                applyCloudWorkspaceLayout(rollback, projections: projections)
            }
            throw DeviceWorkspaceLayoutValidationError.invalidPane
        }
    }

    /// New tabs and splits requested by another Mac run through this Mac's native action.
    func createDeviceWorkspaceTerminal(near panelID: UUID, direction: SurfaceSplitDirection?) -> UUID? {
        guard terminalPanel(for: panelID) != nil, !isRemoteTmuxMirror,
              cloudBindingState.projectedResources[panelID]?.machine.isLocal != false else { return nil }
        if let direction {
            return newTerminalSplit(from: panelID,
                orientation: direction == .left || direction == .right ? .horizontal : .vertical,
                insertFirst: direction == .left || direction == .up, focus: false,
                allowTextBoxFocusDefault: false)?.id
        }
        guard let paneID = paneId(forPanelId: panelID) else { return nil }
        return newTerminalSurface(inPane: paneID, focus: false)?.id
    }
}
