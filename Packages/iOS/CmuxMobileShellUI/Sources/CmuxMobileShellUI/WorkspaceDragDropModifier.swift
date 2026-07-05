import CmuxMobileShellModel
import SwiftUI

struct WorkspaceDragDropModifier: ViewModifier {
    let isEnabled: Bool
    let workspaceID: CmuxMobileShellModel.MobileWorkspacePreview.ID
    let dropTarget: (_ height: CGFloat, _ location: CGPoint) -> CmuxMobileShellModel.MobileWorkspaceDropTarget
    let performDrop: (_ payloads: [String], _ target: CmuxMobileShellModel.MobileWorkspaceDropTarget) -> Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .draggable(workspaceID.rawValue)
                .overlay {
                    GeometryReader { proxy in
                        Color.clear
                            .contentShape(Rectangle())
                            .dropDestination(for: String.self) { payloads, location in
                                performDrop(payloads, dropTarget(proxy.size.height, location))
                            }
                    }
                }
        } else {
            content
        }
    }
}
