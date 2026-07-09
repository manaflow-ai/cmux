public import CmuxSettings
import Foundation

/// A fully resolved config action: the value the surface tab bar, command
/// palette, and keyboard-shortcut paths consume after `cmux.json` `actions`,
/// built-in actions, and commands have been merged into one entry. Carries the
/// resolved title/subtitle/keywords/icon/shortcut plus the
/// ``CmuxSurfaceTabBarButtonAction`` to run.
///
/// This is the pure value shell. The factories that build it from the raw
/// config DTOs and from built-in actions stay app-side, because they resolve
/// user-facing titles with `String(localized:)` (localization is app-bundle
/// resolved) and consume `CmuxConfigActionDefinition`, which is owned by the
/// app target.
public struct CmuxResolvedConfigAction: Identifiable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var keywords: [String]
    public var palette: Bool
    public var shortcut: StoredShortcut?
    public var icon: CmuxButtonIcon?
    public var tooltip: String?
    public var action: CmuxSurfaceTabBarButtonAction
    public var confirm: Bool?
    public var terminalCommandTarget: CmuxConfigTerminalCommandTarget?
    public var actionSourcePath: String?
    public var iconSourcePath: String?

    public init(
        id: String,
        title: String,
        subtitle: String?,
        keywords: [String],
        palette: Bool,
        shortcut: StoredShortcut?,
        icon: CmuxButtonIcon?,
        tooltip: String?,
        action: CmuxSurfaceTabBarButtonAction,
        confirm: Bool?,
        terminalCommandTarget: CmuxConfigTerminalCommandTarget?,
        actionSourcePath: String?,
        iconSourcePath: String?
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.palette = palette
        self.shortcut = shortcut
        self.icon = icon
        self.tooltip = tooltip
        self.action = action
        self.confirm = confirm
        self.terminalCommandTarget = terminalCommandTarget
        self.actionSourcePath = actionSourcePath
        self.iconSourcePath = iconSourcePath
    }

    public var terminalCommand: String? {
        action.terminalCommand
    }

    public var workspaceCommandName: String? {
        action.workspaceCommandName
    }
}
