import Foundation

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
