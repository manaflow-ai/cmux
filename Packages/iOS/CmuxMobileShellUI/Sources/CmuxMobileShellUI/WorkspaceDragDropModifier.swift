import CmuxMobileShellModel
import SwiftUI

struct WorkspaceDragDropModifier: ViewModifier {
    let isEnabled: Bool
    let workspaceID: CmuxMobileShellModel.MobileWorkspacePreview.ID

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .onDrag {
                    MobileWorkspaceDragPayload.provider(for: workspaceID)
                }
        } else {
            content
        }
    }
}
