import SwiftUI

struct SidebarHoverContainerOverlay: NSViewRepresentable {
    let coordinator: SidebarHoverCoordinator

    func makeNSView(context: Context) -> SidebarHoverContainerView {
        SidebarHoverContainerView(coordinator: coordinator)
    }

    func updateNSView(_ nsView: SidebarHoverContainerView, context: Context) {
        nsView.coordinator = coordinator
        nsView.refreshLifecycleBindings()
    }
}
