import CmuxMobileShellModel
import SwiftUI

struct WorkspaceListDropDelegate: DropDelegate {
    let rows: [MobileWorkspaceDropRowFrame]
    let workspaces: [MobileWorkspacePreview]
    let groups: [MobileWorkspaceGroupPreview]
    let viewportSize: CGSize
    @Binding var payload: MobileWorkspaceDropPayload?
    @Binding var target: MobileWorkspaceDropTarget?
    let commit: (MobileWorkspaceDropPayload, MobileWorkspaceMoveIntent) -> Void
    let autoScroll: (CGPoint) -> Void

    func dropEntered(info: DropInfo) {
        updateTarget(at: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateTarget(at: info.location)
        autoScroll(info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        target = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            target = nil
            payload = nil
        }
        guard let payload,
              let resolved = target,
              !resolved.isNoOp else {
            return false
        }
        commit(payload, resolved.intent)
        return true
    }

    private func updateTarget(at point: CGPoint) {
        guard let payload, viewportSize.width > 0 else {
            target = nil
            return
        }
        target = MobileWorkspaceDropResolver().resolve(MobileWorkspaceDropRequest(
            payload: payload,
            rows: rows,
            workspaces: workspaces,
            groups: groups,
            point: point,
            listMidlineX: viewportSize.width / 2
        ))
    }
}
