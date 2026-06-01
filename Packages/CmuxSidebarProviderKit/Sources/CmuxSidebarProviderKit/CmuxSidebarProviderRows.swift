import Foundation

/// Accessory kind shown on a provider row.
public enum CmuxSidebarProviderRowAccessoryKind: String, Codable, Equatable, Sendable {
    /// Opens CMUX's workspace inspector affordance.
    case workspaceInspector
}

/// Accessory control displayed at the trailing edge of a provider row.
public struct CmuxSidebarProviderRowAccessory: Codable, Equatable, Sendable {
    /// Accessory behavior.
    public var kind: CmuxSidebarProviderRowAccessoryKind
    /// SF Symbols name for the accessory icon.
    public var systemImageName: String
    /// Default popover tab when the accessory opens workspace details.
    public var defaultTab: CmuxSidebarProviderWorkspacePopoverTab

    /// Creates a row accessory.
    public init(
        kind: CmuxSidebarProviderRowAccessoryKind,
        systemImageName: String,
        defaultTab: CmuxSidebarProviderWorkspacePopoverTab
    ) {
        self.kind = kind
        self.systemImageName = systemImageName
        self.defaultTab = defaultTab
    }

    /// Standard workspace inspector accessory.
    public static let inspector = CmuxSidebarProviderRowAccessory(
        kind: .workspaceInspector,
        systemImageName: "ellipsis.circle",
        defaultTab: .notes
    )
}

/// Relative-date formatting style for provider text.
public enum CmuxSidebarProviderRelativeDateStyle: String, Codable, Equatable, Sendable {
    /// Compact elapsed-time style for dense sidebar rows.
    case compact
}

/// Shape used behind a provider row icon.
public enum CmuxSidebarProviderIconShape: String, Codable, Equatable, Sendable {
    /// Circular icon background.
    case circle
    /// Rounded-rectangle icon background.
    case roundedRectangle = "rounded-rectangle"
}

/// Icon model for a provider row.
public struct CmuxSidebarProviderIcon: Codable, Equatable, Sendable {
    /// Optional SF Symbols name.
    public var systemImageName: String?
    /// Optional short text fallback.
    public var text: String?
    /// Foreground color as a CSS-style hex string.
    public var foregroundColorHex: String?
    /// Background color as a CSS-style hex string.
    public var backgroundColorHex: String?
    /// Background shape.
    public var shape: CmuxSidebarProviderIconShape

    /// Creates a provider row icon.
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

/// Text value rendered by a sidebar provider row.
public enum CmuxSidebarProviderText: Codable, Equatable, Sendable {
    /// Plain, already-localized text.
    case plain(String)
    /// String catalog backed text.
    case localized(CmuxSidebarProviderLocalizedText)
    /// Relative date text rendered against the current render context.
    case relativeDate(Date, style: CmuxSidebarProviderRelativeDateStyle)

    /// Date carried by relative-date text, if any.
    public var relativeDate: Date? {
        switch self {
        case .plain, .localized:
            return nil
        case .relativeDate(let date, _):
            return date
        }
    }
}

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
