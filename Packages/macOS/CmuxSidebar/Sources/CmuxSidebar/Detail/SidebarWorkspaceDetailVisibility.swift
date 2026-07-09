internal import Foundation

/// Resolved visibility of the primary workspace-row detail lines (the
/// workspace description and the latest notification message).
///
/// Replaces the legacy `SidebarWorkspaceDetailSettings` pure resolvers
/// (`resolvedWorkspaceDescriptionVisibility` /
/// `resolvedNotificationMessageVisibility`): each line shows only when its
/// own toggle is on **and** the master "hide all details" switch is off.
/// Binding both resolved lines in one value keeps the pair from being
/// recombined inconsistently at call sites.
public struct SidebarWorkspaceDetailVisibility: Equatable, Sendable {
    /// Whether the workspace description line is shown.
    public let showsWorkspaceDescription: Bool
    /// Whether the latest notification message line is shown.
    public let showsNotificationMessage: Bool

    /// Resolves the two detail lines from their individual toggles and the
    /// master "hide all details" switch.
    public init(
        showWorkspaceDescription: Bool,
        showNotificationMessage: Bool,
        hideAllDetails: Bool
    ) {
        self.showsWorkspaceDescription = showWorkspaceDescription && !hideAllDetails
        self.showsNotificationMessage = showNotificationMessage && !hideAllDetails
    }
}
