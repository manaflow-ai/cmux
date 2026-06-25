public import CmuxSettings
import Foundation

/// A fully-resolved cmux config action: an ``CmuxConfigActionDefinition`` (or a
/// built-in / command) folded into the concrete values the command palette,
/// shortcut layer, and tab-bar executor read directly.
///
/// Unlike ``CmuxConfigActionDefinition`` (which carries optional overrides), this
/// is the resolved image with a non-optional title, keywords, and palette flag.
/// ``applying(_:strings:)`` overlays a later definition onto an existing resolved
/// action; ``fromDefinition(id:definition:sourcePath:strings:)`` builds one from a
/// raw definition; ``builtIn(_:strings:)`` builds the standard resolved action for
/// a built-in.
///
/// ## Why the localized titles arrive pre-assembled
///
/// Built-in and agent default titles are user-facing strings. `String(localized:)`
/// must resolve against the app bundle (which carries the Japanese catalog), not
/// this package's bundle, so the titles are passed in via ``BuiltInStrings``
/// assembled app-side. Resolving them here would silently drop every non-English
/// translation.
public struct CmuxResolvedConfigAction: Identifiable, Sendable, Hashable {
    /// The action identifier.
    public var id: String
    /// The resolved display title.
    public var title: String
    /// The resolved subtitle.
    public var subtitle: String?
    /// The resolved discovery keywords.
    public var keywords: [String]
    /// Whether the action appears in the command palette.
    public var palette: Bool
    /// The keyboard shortcut bound to the action.
    public var shortcut: StoredShortcut?
    /// The resolved icon.
    public var icon: CmuxButtonIcon?
    /// The resolved tooltip.
    public var tooltip: String?
    /// The typed action this resolves to.
    public var action: CmuxSurfaceTabBarButtonAction
    /// Whether the action prompts for confirmation before running.
    public var confirm: Bool?
    /// Which terminal the action's command targets.
    public var terminalCommandTarget: CmuxConfigTerminalCommandTarget?
    /// The `cmux.json` path the action was declared in.
    public var actionSourcePath: String?
    /// The `cmux.json` path the icon was declared in.
    public var iconSourcePath: String?

    /// Creates a resolved config action.
    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        keywords: [String] = [],
        palette: Bool = true,
        shortcut: StoredShortcut? = nil,
        icon: CmuxButtonIcon? = nil,
        tooltip: String? = nil,
        action: CmuxSurfaceTabBarButtonAction,
        confirm: Bool? = nil,
        terminalCommandTarget: CmuxConfigTerminalCommandTarget? = nil,
        actionSourcePath: String? = nil,
        iconSourcePath: String? = nil
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

    /// The terminal command this action runs, if any.
    public var terminalCommand: String? {
        action.terminalCommand
    }

    /// The workspace command this action runs, if any.
    public var workspaceCommandName: String? {
        action.workspaceCommandName
    }

    /// Localized titles for built-in and agent default actions, assembled
    /// app-side so `String(localized:)` binds to the app bundle.
    ///
    /// Passed into ``CmuxResolvedConfigAction/builtIn(_:strings:)`` and
    /// ``CmuxResolvedConfigAction/fromDefinition(id:definition:sourcePath:strings:)``
    /// so the resolved titles keep their Japanese translations.
    public struct BuiltInStrings: Sendable {
        /// Title for ``CmuxSurfaceTabBarBuiltInAction/newWorkspace``.
        public var newWorkspace: String
        /// Title for ``CmuxSurfaceTabBarBuiltInAction/cloudVM``.
        public var cloudVM: String
        /// Title for ``CmuxSurfaceTabBarBuiltInAction/newTerminal``.
        public var newTerminal: String
        /// Title for ``CmuxSurfaceTabBarBuiltInAction/newBrowser``.
        public var newBrowser: String
        /// Title for ``CmuxSurfaceTabBarBuiltInAction/splitRight``.
        public var splitRight: String
        /// Title for ``CmuxSurfaceTabBarBuiltInAction/splitDown``.
        public var splitDown: String
        /// Subtitle shown under every built-in action (`"cmux"`).
        public var builtInSubtitle: String
        /// Default title for a `codex` agent action.
        public var codex: String
        /// Default title for a `claudeCode` agent action.
        public var claudeCode: String

        /// Creates the built-in title bundle.
        public init(
            newWorkspace: String,
            cloudVM: String,
            newTerminal: String,
            newBrowser: String,
            splitRight: String,
            splitDown: String,
            builtInSubtitle: String,
            codex: String,
            claudeCode: String
        ) {
            self.newWorkspace = newWorkspace
            self.cloudVM = cloudVM
            self.newTerminal = newTerminal
            self.newBrowser = newBrowser
            self.splitRight = splitRight
            self.splitDown = splitDown
            self.builtInSubtitle = builtInSubtitle
            self.codex = codex
            self.claudeCode = claudeCode
        }

        /// The title for a built-in action.
        func title(for builtIn: CmuxSurfaceTabBarBuiltInAction) -> String {
            switch builtIn {
            case .newWorkspace: return newWorkspace
            case .cloudVM: return cloudVM
            case .newTerminal: return newTerminal
            case .newBrowser: return newBrowser
            case .splitRight: return splitRight
            case .splitDown: return splitDown
            }
        }
    }

    /// Overlays a later definition onto this resolved action, taking each
    /// non-nil override from `definition` and recording the icon's source path.
    public func applying(
        _ definition: CmuxConfigActionDefinition,
        sourcePath: String?
    ) -> CmuxResolvedConfigAction? {
        var next = self
        next.title = definition.title ?? next.title
        next.subtitle = definition.subtitle ?? next.subtitle
        if let keywords = definition.keywords {
            next.keywords = keywords
        }
        next.palette = definition.palette ?? next.palette
        next.shortcut = definition.shortcut ?? next.shortcut
        if let icon = definition.icon {
            next.icon = icon
            next.iconSourcePath = sourcePath
        }
        next.tooltip = definition.tooltip ?? next.tooltip
        next.confirm = definition.confirm ?? next.confirm
        next.terminalCommandTarget = definition.terminalCommandTarget ?? next.terminalCommandTarget
        next.actionSourcePath = sourcePath ?? next.actionSourcePath
        if let action = definition.action {
            next.action = action
        }
        return next
    }

    /// Builds a resolved action from a raw definition, deriving the title from
    /// the definition's title, tooltip, or a default for the action kind.
    /// Returns `nil` when the definition declares no runnable action.
    public static func fromDefinition(
        id: String,
        definition: CmuxConfigActionDefinition,
        sourcePath: String?,
        strings: BuiltInStrings
    ) -> CmuxResolvedConfigAction? {
        guard let action = definition.action else { return nil }
        let title = definition.title
            ?? definition.tooltip
            ?? Self.defaultTitle(for: id, action: action, strings: strings)
        return CmuxResolvedConfigAction(
            id: id,
            title: title,
            subtitle: definition.subtitle,
            keywords: definition.keywords ?? [],
            palette: definition.palette ?? true,
            shortcut: definition.shortcut,
            icon: definition.icon ?? action.defaultButtonIcon,
            tooltip: definition.tooltip,
            action: action,
            confirm: definition.confirm,
            terminalCommandTarget: definition.terminalCommandTarget,
            actionSourcePath: sourcePath,
            iconSourcePath: definition.icon == nil ? nil : sourcePath
        )
    }

    /// Builds the standard resolved action for a built-in, using the localized
    /// title and the fixed discovery keywords for each built-in case.
    public static func builtIn(
        _ builtIn: CmuxSurfaceTabBarBuiltInAction,
        strings: BuiltInStrings
    ) -> CmuxResolvedConfigAction {
        let keywords: [String]
        switch builtIn {
        case .newWorkspace:
            keywords = ["create", "new", "workspace"]
        case .cloudVM:
            keywords = ["cloud", "vm", "virtual", "machine", "remote"]
        case .newTerminal:
            keywords = ["new", "terminal", "tab", "surface"]
        case .newBrowser:
            keywords = ["new", "browser", "tab", "surface"]
        case .splitRight:
            keywords = ["terminal", "split", "right"]
        case .splitDown:
            keywords = ["terminal", "split", "down"]
        }

        return CmuxResolvedConfigAction(
            id: builtIn.configID,
            title: strings.title(for: builtIn),
            subtitle: strings.builtInSubtitle,
            keywords: keywords,
            palette: true,
            shortcut: nil,
            icon: .symbol(builtIn.defaultIcon),
            tooltip: nil,
            action: .builtIn(builtIn),
            confirm: nil,
            terminalCommandTarget: nil,
            actionSourcePath: nil,
            iconSourcePath: nil
        )
    }

    private static func defaultTitle(
        for id: String,
        action: CmuxSurfaceTabBarButtonAction,
        strings: BuiltInStrings
    ) -> String {
        switch action {
        case .agent(let agent, _):
            switch agent {
            case .codex:
                return strings.codex
            case .claudeCode:
                return strings.claudeCode
            }
        case .command:
            return id
        case .workspaceCommand(let commandName):
            return commandName
        case .builtIn(let builtIn):
            return builtIn.configID
        case .actionReference(let identifier):
            return identifier
        }
    }
}
