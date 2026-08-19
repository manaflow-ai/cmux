import AppKit
import SwiftUI

/// View modifier replacing SwiftUI `.onDrag` on sidebar rows with an
/// AppKit-owned drag source (`beginDraggingSession`). The exclusive
/// `DragGesture` reproduces `.onDrag`'s behavior: a drag beyond the threshold
/// cancels the row's tap/Button press, while a clean click still selects.
///
/// The coordinator is read from the environment (injected once above the
/// `LazyVStack` boundary), so rows keep receiving only value snapshots and
/// action closures. Fails closed: no coordinator in the environment means no
/// drag source, never a crash.
private struct AppKitTabDragModifier: ViewModifier {
    let workspaceId: UUID
    let isEditing: Bool

    @Environment(\.sidebarTabDragCoordinator) private var coordinator

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEditing || coordinator == nil {
            // No drag source while renaming inline, so text selection/dragging
            // inside the rename field never starts a sidebar reorder (same gate
            // as the `.sidebarRowDragGate` it replaces). A missing coordinator
            // (view mounted outside the sidebar) also disables the drag source
            // instead of crashing.
            content
        } else {
            content
                .overlay {
                    SidebarTabDragAnchorView(workspaceId: workspaceId, coordinator: coordinator!)
                        .allowsHitTesting(false)
                }
                .highPriorityGesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { value in
                            guard let coordinator,
                                  // Nil event = no reliable window (anchor
                                  // detached, nothing cached): skip the begin
                                  // attempt rather than drag in a wrong
                                  // coordinate space.
                                  let event = coordinator.dragEvent(for: workspaceId, location: value.location) else { return }
                            _ = coordinator.beginDrag(
                                workspaceId: workspaceId,
                                event: event,
                                makeImage: coordinator.dragImage(view:frame:)
                            )
                        }
                )
        }
    }
}

extension View {
    /// Replaces SwiftUI `.onDrag` + `.internalOnlyTabDrag()` on a sidebar row.
    /// The AppKit session always concludes via `draggingSession(_:endedAt:)`,
    /// which is what restores system-wide gestures after a drag. The drag
    /// coordinator comes from `\.sidebarTabDragCoordinator` in the environment.
    func appKitTabDrag(
        workspaceId: UUID,
        isEditing: Bool
    ) -> some View {
        modifier(AppKitTabDragModifier(
            workspaceId: workspaceId,
            isEditing: isEditing
        ))
    }
}
