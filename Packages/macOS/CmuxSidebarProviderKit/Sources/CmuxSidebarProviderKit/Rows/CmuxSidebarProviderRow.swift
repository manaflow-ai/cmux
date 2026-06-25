import Foundation

/// Row rendered inside a provider section.
public struct CmuxSidebarProviderRow: Identifiable, Codable, Equatable, Sendable {
    /// Stable row id.
    public var id: UUID
    /// Primary row title.
    public var title: String
    /// Workspace represented by the row.
    public var workspaceId: UUID
    /// Optional trailing accessory.
    public var accessory: CmuxSidebarProviderRowAccessory?
    /// Optional subtitle.
    public var subtitle: CmuxSidebarProviderText?
    /// Optional semantic role for the subtitle.
    public var subtitleRole: CmuxSidebarProviderRowSubtitleRole?
    /// Optional trailing text.
    public var trailingText: CmuxSidebarProviderText?
    /// Optional leading icon.
    public var leadingIcon: CmuxSidebarProviderIcon?

    /// Creates a provider row.
    public init(
        id: UUID,
        title: String,
        workspaceId: UUID,
        accessory: CmuxSidebarProviderRowAccessory?,
        subtitle: CmuxSidebarProviderText? = nil,
        subtitleRole: CmuxSidebarProviderRowSubtitleRole? = nil,
        trailingText: CmuxSidebarProviderText? = nil,
        leadingIcon: CmuxSidebarProviderIcon? = nil
    ) {
        self.id = id
        self.title = title
        self.workspaceId = workspaceId
        self.accessory = accessory
        self.subtitle = subtitle
        self.subtitleRole = subtitleRole
        self.trailingText = trailingText
        self.leadingIcon = leadingIcon
    }
}
