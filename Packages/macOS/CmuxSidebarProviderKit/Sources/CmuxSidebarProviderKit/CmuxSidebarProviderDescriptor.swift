import Foundation

/// Stable metadata CMUX uses to identify and present an in-process sidebar provider.
public struct CmuxSidebarProviderDescriptor: Identifiable, Codable, Equatable, Sendable {
    /// Provider id for the built-in workspace sidebar.
    public static let defaultWorkspacesID = "cmux.sidebar.default"

    /// Stable provider identifier persisted in user selection state.
    public var id: String
    /// Localized provider title shown in sidebar provider menus.
    public var title: CmuxSidebarProviderLocalizedText
    /// Optional localized detail text shown under the provider title.
    public var subtitle: CmuxSidebarProviderLocalizedText?
    /// SF Symbols name used for this provider in menus.
    public var systemImageName: String
    /// Whether the provider is supplied by CMUX rather than a package example.
    public var isHostProvided: Bool

    /// Creates sidebar provider metadata.
    public init(
        id: String,
        title: CmuxSidebarProviderLocalizedText,
        subtitle: CmuxSidebarProviderLocalizedText? = nil,
        systemImageName: String,
        isHostProvided: Bool
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImageName = systemImageName
        self.isHostProvided = isHostProvided
    }

    /// Descriptor for CMUX's built-in workspace sidebar.
    public static let defaultWorkspaces = CmuxSidebarProviderDescriptor(
        id: defaultWorkspacesID,
        title: CmuxSidebarProviderLocalizedText(key: "sidebar.provider.default.title", defaultValue: "Default Workspaces"),
        subtitle: CmuxSidebarProviderLocalizedText(key: "sidebar.provider.default.subtitle", defaultValue: "cmux"),
        systemImageName: "list.bullet",
        isHostProvided: true
    )
}
