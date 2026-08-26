import Bonsplit
import Foundation

extension CloudTreeOpenTarget {
    /// The open target for a Bonsplit drop: the dropped-on pane, a surface in it to
    /// split from, and the side. Mirrors how `Workspace.handleSessionDrop` reads the
    /// same destination: a horizontal split is left/right and a vertical one up/down,
    /// with `insertFirst` meaning the new pane goes on the first (left/top) side; an
    /// insert becomes a tab in the pane at the requested index.
    static func dropTarget(
        destination: BonsplitController.ExternalTabDropRequest.Destination,
        surfaceID: UUID?
    ) -> CloudTreeOpenTarget {
        switch destination {
        case .insert(let paneID, let index):
            return CloudTreeOpenTarget(paneID: paneID.id.uuidString, surfaceID: surfaceID?.uuidString, direction: nil, tabIndex: index)
        case .split(let paneID, let orientation, let insertFirst):
            let direction: CloudTreeSplitDirection
            switch orientation {
            case .horizontal: direction = insertFirst ? .left : .right
            case .vertical: direction = insertFirst ? .up : .down
            }
            return CloudTreeOpenTarget(paneID: paneID.id.uuidString, surfaceID: surfaceID?.uuidString, direction: direction, tabIndex: nil)
        }
    }
}

extension Workspace {
    /// Opens a Cloud tree row dropped into this workspace: a machine's terminal
    /// becomes a pane attached through the machine's cmux-tui link, its desktop
    /// or a forwarded port becomes a browser pane. All three go through the
    /// app-side `CloudTreeServicing` — the same path `cmux vm open` uses — with
    /// the real drop destination (pane, side, or tab index) carried as the open
    /// target, so the pane lands exactly where a Vault session or a file dropped
    /// at the same spot would. The drop is accepted as soon as the request is
    /// dispatched; the async open reports failures through the service.
    @discardableResult
    @MainActor
    func handleCloudSurfaceDrop(
        item: CloudTreeDragItem,
        destination: BonsplitController.ExternalTabDropRequest.Destination,
        service: (any CloudTreeServicing)? = nil
    ) -> Bool {
        guard let service = service ?? CloudTreeServiceAccess.shared else { return false }
        let targetPane: PaneID
        switch destination {
        case .insert(let paneID, _): targetPane = paneID
        case .split(let paneID, _, _): targetPane = paneID
        }
        let target = CloudTreeOpenTarget.dropTarget(
            destination: destination,
            surfaceID: selectedPanelForPaneDrop(in: targetPane)?.panelId
        )
        let workspaceID = id.uuidString
#if DEBUG
        cmuxDebugLog("cloudTree.drop workspace=\(workspaceID.prefix(5)) item=\(item) target=\(target)")
#endif
        Task { @MainActor in
            do {
                switch item {
                case .terminal(let machineID, let terminalID, _):
                    _ = try await service.openTerminal(
                        machineID: machineID,
                        terminalID: terminalID,
                        workspaceID: workspaceID,
                        placement: target.placement,
                        focus: true,
                        target: target
                    )
                case .desktop(let machineID):
                    _ = try await service.openDesktop(machineID: machineID, workspaceID: workspaceID, focus: true, target: target)
                case .port(let machineID, let port):
                    _ = try await service.openPort(machineID: machineID, port: port, workspaceID: workspaceID, target: target)
                }
            } catch {
#if DEBUG
                cmuxDebugLog("cloudTree.drop.failed item=\(item) error=\(error)")
#endif
            }
        }
        return true
    }
}
