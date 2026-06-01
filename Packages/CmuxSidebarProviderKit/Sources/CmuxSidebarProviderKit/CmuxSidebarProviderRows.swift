import Foundation

public enum CmuxSidebarProviderRowAccessoryKind: String, Codable, Equatable, Sendable {
    case workspaceInspector
}

public struct CmuxSidebarProviderRowAccessory: Codable, Equatable, Sendable {
    public var kind: CmuxSidebarProviderRowAccessoryKind
    public var systemImageName: String
    public var defaultTab: CmuxSidebarProviderWorkspacePopoverTab

    public init(
        kind: CmuxSidebarProviderRowAccessoryKind,
        systemImageName: String,
        defaultTab: CmuxSidebarProviderWorkspacePopoverTab
    ) {
        self.kind = kind
        self.systemImageName = systemImageName
        self.defaultTab = defaultTab
    }

    public static let inspector = CmuxSidebarProviderRowAccessory(
        kind: .workspaceInspector,
        systemImageName: "ellipsis.circle",
        defaultTab: .notes
    )
}

public enum CmuxSidebarProviderRelativeDateStyle: String, Codable, Equatable, Sendable {
    case compact
}

public enum CmuxSidebarProviderIconShape: String, Codable, Equatable, Sendable {
    case circle
    case roundedRectangle = "rounded-rectangle"
}

public struct CmuxSidebarProviderIcon: Codable, Equatable, Sendable {
    public var systemImageName: String?
    public var text: String?
    public var foregroundColorHex: String?
    public var backgroundColorHex: String?
    public var shape: CmuxSidebarProviderIconShape

    public init(
        systemImageName: String? = nil,
        text: String? = nil,
        foregroundColorHex: String? = nil,
        backgroundColorHex: String? = nil,
        shape: CmuxSidebarProviderIconShape = .circle
    ) {
        self.systemImageName = systemImageName
        self.text = text
        self.foregroundColorHex = foregroundColorHex
        self.backgroundColorHex = backgroundColorHex
        self.shape = shape
    }
}

public enum CmuxSidebarProviderText: Codable, Equatable, Sendable {
    case plain(String)
    case localized(CmuxSidebarProviderLocalizedText)
    case relativeDate(Date, style: CmuxSidebarProviderRelativeDateStyle)

    public var relativeDate: Date? {
        switch self {
        case .plain, .localized:
            return nil
        case .relativeDate(let date, _):
            return date
        }
    }
}

public struct CmuxSidebarProviderRow: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var workspaceId: UUID
    public var accessory: CmuxSidebarProviderRowAccessory?
    public var subtitle: CmuxSidebarProviderText?
    public var trailingText: CmuxSidebarProviderText?
    public var leadingIcon: CmuxSidebarProviderIcon?

    public init(
        id: UUID,
        title: String,
        workspaceId: UUID,
        accessory: CmuxSidebarProviderRowAccessory?,
        subtitle: CmuxSidebarProviderText? = nil,
        trailingText: CmuxSidebarProviderText? = nil,
        leadingIcon: CmuxSidebarProviderIcon? = nil
    ) {
        self.id = id
        self.title = title
        self.workspaceId = workspaceId
        self.accessory = accessory
        self.subtitle = subtitle
        self.trailingText = trailingText
        self.leadingIcon = leadingIcon
    }
}
