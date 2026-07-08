import SwiftUI

struct SidebarWorkspaceRowHoverTrackingModifier: ViewModifier {
    @Binding var rowInteractionState: SidebarWorkspaceRowInteractionState

    func body(content: Content) -> some View {
        content
            .overlay {
                SidebarWorkspaceRowHoverReconciler { hovering in
                    rowInteractionState.setPointerHovering(hovering)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onDisappear {
                rowInteractionState.setPointerHovering(false)
            }
    }
}

extension View {
    func sidebarWorkspaceRowHoverTracking(
        _ rowInteractionState: Binding<SidebarWorkspaceRowInteractionState>
    ) -> some View {
        modifier(SidebarWorkspaceRowHoverTrackingModifier(rowInteractionState: rowInteractionState))
    }
}
