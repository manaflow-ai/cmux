import Foundation

public struct CmuxSidebarProviderDescriptor: Identifiable, Codable, Equatable, Sendable {
    public static let defaultWorkspacesID = "cmux.sidebar.default"

    public var id: String
    public var title: CmuxSidebarProviderLocalizedText
    public var subtitle: CmuxSidebarProviderLocalizedText?
    public var systemImageName: String
    public var isHostProvided: Bool

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

    public static let defaultWorkspaces = CmuxSidebarProviderDescriptor(
        id: defaultWorkspacesID,
        title: CmuxSidebarProviderLocalizedText(key: "sidebar.provider.default.title", defaultValue: "Default Workspaces"),
        subtitle: CmuxSidebarProviderLocalizedText(key: "sidebar.provider.default.subtitle", defaultValue: "cmux"),
        systemImageName: "list.bullet",
        isHostProvided: true
    )
}
