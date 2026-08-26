import Bonsplit
import Foundation

extension Workspace {
    /// Opens a Cloud tree row dropped into this workspace: a machine's terminal
    /// becomes a pane attached through the machine's cmux-tui link, its desktop
    /// or a forwarded port becomes a browser pane. All three go through the
    /// app-side `CloudTreeServicing` — the same path `cmux vm open` uses.
    ///
    /// Handoff: the service opens relative to the *focused* pane of the target
    /// workspace (`CloudTreePlacement` carries split/tab, not a pane or an
    /// orientation), so the drop pane is focused first; a `.split` destination
    /// then splits that pane with the service's default orientation and an
    /// `.insert` destination adds a tab to it. The drop is accepted as soon as
    /// the request is dispatched; the async open reports failures through the
    /// service.
    @discardableResult
    @MainActor
    func handleCloudSurfaceDrop(
        item: CloudTreeDragItem,
        destination: BonsplitController.ExternalTabDropRequest.Destination,
        service: (any CloudTreeServicing)? = CloudTreeServiceAccess.shared
    ) -> Bool {
        guard let service else { return false }
        let targetPane: PaneID
        let placement: CloudTreePlacement
        switch destination {
        case .insert(let paneId, _):
            targetPane = paneId
            placement = .tab
        case .split(let paneId, _, _):
            targetPane = paneId
            placement = .split
        }
        if let selected = selectedPanelForPaneDrop(in: targetPane) {
            focusPanel(selected.panelId)
        }
        let workspaceID = id.uuidString
#if DEBUG
        cmuxDebugLog("cloudTree.drop workspace=\(workspaceID.prefix(5)) item=\(item) placement=\(placement.rawValue)")
#endif
        Task { @MainActor in
            do {
                switch item {
                case .terminal(let machineID, let terminalID, _):
                    _ = try await service.openTerminal(
                        machineID: machineID,
                        terminalID: terminalID,
                        workspaceID: workspaceID,
                        placement: placement,
                        focus: true
                    )
                case .desktop(let machineID):
                    _ = try await service.openDesktop(machineID: machineID, workspaceID: workspaceID, focus: true)
                case .port(let machineID, let port):
                    _ = try await service.openPort(machineID: machineID, port: port, workspaceID: workspaceID)
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
