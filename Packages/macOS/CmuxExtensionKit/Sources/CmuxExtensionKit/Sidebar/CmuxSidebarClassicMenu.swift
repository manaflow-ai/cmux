import Foundation

/// Requests presentation of the host's existing classic menu. The extension
/// cannot select a menu item or pass a command, path, link, or notification.
/// The explicit scope authorizes native UI presentation; mutations remain
/// user gestures in CMUX's existing menu and confirmation handlers.
public enum CmuxSidebarClassicMenuAction: Codable, Equatable, Sendable {
    case presentWorkspaceMenu(workspaceID: UUID, selectedWorkspaceIDs: [UUID])
    case presentGroupMenu(groupID: UUID)

    public var requiredActionScopeNames: Set<String> { ["presentNativeSidebarMenu"] }
}
