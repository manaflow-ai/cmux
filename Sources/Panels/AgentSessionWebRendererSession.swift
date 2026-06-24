import Foundation

@MainActor
final class AgentSessionWebRendererSession {
    private let ownedCoordinator = AgentSessionWebRendererCoordinator()
    var onHasActiveProviderChanged: ((Bool) -> Void)? {
        didSet {
            ownedCoordinator.onHasActiveProviderChanged = onHasActiveProviderChanged
        }
    }
    var onProviderSelectionChanged: ((AgentSessionProviderID, String?, String?, String?) -> Void)? {
        didSet {
            ownedCoordinator.onProviderSelectionChanged = onProviderSelectionChanged
        }
    }

    func coordinator(
        panelId: UUID,
        workspaceId: UUID,
        rendererKind: AgentSessionRendererKind,
        initialProviderID: AgentSessionProviderID,
        initialModelID: String?,
        initialOpenCodeProviderID: String?,
        initialProviderSelectionID: String?,
        workingDirectory: String?,
        theme: AgentSessionWebTheme,
        isFocused: Bool
    ) -> AgentSessionWebRendererCoordinator {
        ownedCoordinator.bind(
            panelId: panelId,
            workspaceId: workspaceId,
            rendererKind: rendererKind,
            initialProviderID: initialProviderID,
            initialModelID: initialModelID,
            initialOpenCodeProviderID: initialOpenCodeProviderID,
            initialProviderSelectionID: initialProviderSelectionID,
            workingDirectory: workingDirectory,
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
