import SwiftUI

struct SidebarRowHoverTrackingRepresentable: NSViewRepresentable {
    let rowID: UUID
    let coordinator: SidebarHoverCoordinator
    @Binding var isHovered: Bool

    func makeNSView(context: Context) -> SidebarRowHoverTrackingView {
        SidebarRowHoverTrackingView(
            rowID: rowID,
            coordinator: coordinator,
            setHovered: { hovered in
                isHovered = hovered
            }
        )
    }

    func updateNSView(_ nsView: SidebarRowHoverTrackingView, context: Context) {
        nsView.rowID = rowID
        nsView.coordinator = coordinator
        nsView.setHovered = { hovered in
            isHovered = hovered
        }
        nsView.refreshRegistration()
    }
}
