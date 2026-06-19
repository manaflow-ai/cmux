import Foundation

/// Owns the long-lived ``KanbanWebRendererCoordinator`` for a ``KanbanPanel``.
///
/// Mirrors ``AgentSessionWebRendererSession``: SwiftUI rebuilds the
/// `NSViewRepresentable` repeatedly, so the coordinator (which holds the
/// `WKWebView` and the board repository) must outlive those rebuilds. The panel
/// holds one session; the session holds one coordinator.
@MainActor
final class KanbanWebRendererSession {
    private let ownedCoordinator = KanbanWebRendererCoordinator()

    func coordinator(
        panelId: UUID,
        workspaceId: UUID,
        rendererKind: KanbanRendererKind,
        theme: AgentSessionWebTheme,
        isFocused: Bool
    ) -> KanbanWebRendererCoordinator {
        ownedCoordinator.bind(
            panelId: panelId,
            workspaceId: workspaceId,
            rendererKind: rendererKind,
            theme: theme,
            isFocused: isFocused
        )
        return ownedCoordinator
    }

    func focus() {
        ownedCoordinator.focus()
    }

    func unfocus() {
        ownedCoordinator.unfocus()
    }

    func close() {
        ownedCoordinator.close()
    }
}
