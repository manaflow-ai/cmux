import AppKit
import SwiftUI

struct SidebarRowHoverRegistrationModifier: ViewModifier {
    let rowID: UUID
    let coordinator: SidebarHoverCoordinator
    @Binding var isHovered: Bool

    func body(content: Content) -> some View {
        content.background(
            SidebarRowHoverTrackingRepresentable(
                rowID: rowID,
                coordinator: coordinator,
                isHovered: $isHovered
            )
        )
    }
}

extension View {
    func sidebarRowHoverRegistration(
        rowID: UUID,
        coordinator: SidebarHoverCoordinator,
        isHovered: Binding<Bool>
    ) -> some View {
        modifier(
            SidebarRowHoverRegistrationModifier(
                rowID: rowID,
                coordinator: coordinator,
                isHovered: isHovered
            )
        )
    }
}
