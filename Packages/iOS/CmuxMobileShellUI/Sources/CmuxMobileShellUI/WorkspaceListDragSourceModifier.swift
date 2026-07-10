import CmuxMobileShellModel
import SwiftUI

struct WorkspaceListDragSourceModifier: ViewModifier {
    let payload: MobileWorkspaceDropPayload
    let isEnabled: Bool
    let beginDrag: (MobileWorkspaceDropPayload) -> NSItemProvider

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.onDrag { beginDrag(payload) }
        } else {
            content
        }
    }
}
