import Foundation

// Compatibility names used only by the existing cmux app while the old prototype
// sidebar is removed in smaller follow-up steps.
public enum CmuxExtensionSidebarProviderID {
    public static let defaultWorkspaces = "cmux.sidebar.default"
}

public struct CmuxExtensionLocalizedText: Codable, Equatable, Hashable, Sendable {
    public var key: String
    public var defaultValue: String

    public init(key: String, defaultValue: String) {
        self.key = key
        self.defaultValue = defaultValue
    }
}

public struct CmuxExtensionSidebarProviderDescriptor: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: CmuxExtensionLocalizedText
    public var subtitle: CmuxExtensionLocalizedText?
    public var systemImageName: String
    public var isHostProvided: Bool

    public init(
        id: String,
        title: CmuxExtensionLocalizedText,
        subtitle: CmuxExtensionLocalizedText? = nil,
        systemImageName: String,
        isHostProvided: Bool
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImageName = systemImageName
        self.isHostProvided = isHostProvided
    }

    public static let defaultWorkspaces = CmuxExtensionSidebarProviderDescriptor(
        id: CmuxExtensionSidebarProviderID.defaultWorkspaces,
        title: CmuxExtensionLocalizedText(key: "sidebar.provider.default.title", defaultValue: "Default Workspaces"),
        subtitle: CmuxExtensionLocalizedText(key: "sidebar.provider.default.subtitle", defaultValue: "cmux"),
        systemImageName: "list.bullet",
        isHostProvided: true
    )
}

public protocol CmuxExtensionSidebarProvider: Sendable {
    var descriptor: CmuxExtensionSidebarProviderDescriptor { get }
}
