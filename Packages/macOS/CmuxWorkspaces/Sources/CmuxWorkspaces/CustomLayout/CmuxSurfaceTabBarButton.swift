public import Bonsplit
import Foundation

/// One configured surface tab-bar button in the `cmux.json` wire schema.
///
/// A button pairs an id with a typed ``CmuxSurfaceTabBarButtonAction`` plus
/// optional presentation overrides (title, icon, tooltip) and execution metadata
/// (confirm flag, terminal-command target, and the `cmux.json` source paths used
/// to authorize project-local actions and icons). Its ``init(from:)`` accepts the
/// legacy bare-string form, the explicit `action`/`builtin`/`command`/`agent`/
/// `type` forms (exactly one allowed), and rejects ambiguous combinations.
///
/// ``defaults`` is the built-in four-button row; the ``builtIn(_:id:title:icon:tooltip:)``
/// and ``actionReference(_:title:icon:tooltip:)`` factories build the standard
/// entries. ``bonsplitActionButton(configSourcePath:globalConfigPath:allowProjectLocalIcon:)``
/// projects the button into the Bonsplit appearance model, and
/// ``resolved(actions:codingPath:)`` folds a referenced `actions` template back
/// into a concrete button.
public struct CmuxSurfaceTabBarButton: Codable, Sendable, Hashable, Identifiable {
    /// The stable button identifier.
    public var id: String
    /// The display title override.
    public var title: String?
    /// The icon override.
    public var icon: CmuxButtonIcon?
    /// The tooltip override.
    public var tooltip: String?
    /// The typed action the button runs.
    public var action: CmuxSurfaceTabBarButtonAction
    /// Whether the button prompts for confirmation before running.
    public var confirm: Bool?
    /// Which terminal the button's command targets.
    public var terminalCommandTarget: CmuxConfigTerminalCommandTarget?
    /// The `cmux.json` path the action was declared in (authorizes project-local commands).
    public var actionSourcePath: String?
    /// The `cmux.json` path the icon was declared in (authorizes project-local images).
    public var iconSourcePath: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case icon
        case tooltip
        case action
        case builtin
        case command
        case agent
        case args
        case type
        case commandName
        case name
        case confirm
        case target
    }

    /// The "new terminal" built-in button (an action reference).
    public static let newTerminal = actionReference(CmuxSurfaceTabBarBuiltInAction.newTerminal.configID)
    /// The "new browser" built-in button (an action reference).
    public static let newBrowser = actionReference(CmuxSurfaceTabBarBuiltInAction.newBrowser.configID)
    /// The "split right" built-in button (an action reference).
    public static let splitRight = actionReference(CmuxSurfaceTabBarBuiltInAction.splitRight.configID)
    /// The "split down" built-in button (an action reference).
    public static let splitDown = actionReference(CmuxSurfaceTabBarBuiltInAction.splitDown.configID)

    /// The default surface tab-bar button row when the config does not override it.
    public static let defaults: [CmuxSurfaceTabBarButton] = [
        .newTerminal,
        .newBrowser,
        .splitRight,
        .splitDown
    ]

    /// Builds a button that runs a built-in action directly.
    public static func builtIn(
        _ action: CmuxSurfaceTabBarBuiltInAction,
        id: String? = nil,
        title: String? = nil,
        icon: CmuxButtonIcon? = nil,
        tooltip: String? = nil
    ) -> CmuxSurfaceTabBarButton {
        CmuxSurfaceTabBarButton(
            id: id ?? action.configID,
            title: title,
            icon: icon,
            tooltip: tooltip,
            action: .builtIn(action),
            confirm: nil,
            terminalCommandTarget: nil
        )
    }

    /// Builds a button that references an `actions` template by id.
    public static func actionReference(
        _ actionID: String,
        title: String? = nil,
        icon: CmuxButtonIcon? = nil,
        tooltip: String? = nil
    ) -> CmuxSurfaceTabBarButton {
        CmuxSurfaceTabBarButton(
            id: actionID,
            title: title,
            icon: icon,
            tooltip: tooltip,
            action: .actionReference(actionID)
        )
    }

    /// The terminal command this button runs, if any.
    public var command: String? {
        action.terminalCommand
    }

    /// The terminal command this button runs, if any.
    public var terminalCommand: String? {
        action.terminalCommand
    }

    /// The terminal target, defaulting to the standard action target.
    public var resolvedTerminalCommandTarget: CmuxConfigTerminalCommandTarget {
        terminalCommandTarget ?? CmuxConfigTerminalCommandTarget.defaultForActions
    }

    /// The workspace command this button runs, if any.
    public var workspaceCommandName: String? {
        action.workspaceCommandName
    }

    /// Projects this button into a Bonsplit split-action button for the pane
    /// overlay, resolving its icon against the appropriate config source path.
    public func bonsplitActionButton(
        configSourcePath: String?,
        globalConfigPath: String,
        allowProjectLocalIcon: Bool = true
    ) -> BonsplitConfiguration.SplitActionButton {
        let bonsplitAction: BonsplitConfiguration.SplitActionButton.Action = {
            switch action {
            case .builtIn(let builtIn):
                return builtIn.bonsplitAction ?? .custom(id)
            case .command, .agent, .workspaceCommand, .actionReference:
                return .custom(id)
            }
        }()

        return BonsplitConfiguration.SplitActionButton(
            id: id,
            icon: (icon ?? action.defaultButtonIcon).bonsplitIcon(
                configSourcePath: iconSourcePath ?? configSourcePath,
                globalConfigPath: globalConfigPath,
                allowProjectLocalImage: allowProjectLocalIcon
            ),
            tooltip: tooltip ?? title ?? terminalCommand,
            action: bonsplitAction
        )
    }

    /// Creates a surface tab-bar button.
    public init(
        id: String,
        title: String? = nil,
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
        self.icon = icon
        self.tooltip = tooltip
        self.action = action
        self.confirm = confirm
        self.terminalCommandTarget = terminalCommandTarget
        self.actionSourcePath = actionSourcePath
        self.iconSourcePath = iconSourcePath
    }

    public init(from decoder: any Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode(String.self) {
            let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "surface tab bar button action must not be blank"
                    )
                )
            }
            self = CmuxSurfaceTabBarButton(
                id: CmuxSurfaceTabBarBuiltInAction(configID: trimmed)?.configID ?? trimmed,
                action: .actionReference(CmuxSurfaceTabBarBuiltInAction(configID: trimmed)?.configID ?? trimmed)
            )
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let explicitId = try Self.trimmedString(forKey: .id, in: container)
        let explicitTitle = try Self.trimmedString(forKey: .title, in: container, allowBlankAsNil: true)
        let explicitIcon = try container.decodeIfPresent(CmuxButtonIcon.self, forKey: .icon)
        let explicitTooltip = try Self.trimmedString(forKey: .tooltip, in: container, allowBlankAsNil: true)
        let rawAction = try Self.trimmedString(forKey: .action, in: container)
        let rawBuiltin = try Self.trimmedString(forKey: .builtin, in: container)
        let rawCommand = try Self.trimmedString(forKey: .command, in: container)
        let rawAgent = try container.decodeIfPresent(CmuxConfigAgentKind.self, forKey: .agent)
        let rawArgs = try Self.trimmedString(forKey: .args, in: container, allowBlankAsNil: true)
        let rawType = try Self.trimmedString(forKey: .type, in: container)
        let rawCommandName = try Self.trimmedString(forKey: .commandName, in: container)
            ?? Self.trimmedString(forKey: .name, in: container)
        confirm = try container.decodeIfPresent(Bool.self, forKey: .confirm)
        terminalCommandTarget = try container.decodeIfPresent(CmuxConfigTerminalCommandTarget.self, forKey: .target)
        actionSourcePath = nil
        iconSourcePath = nil

        let definedActionForms = [
            rawAction != nil,
            rawBuiltin != nil,
            rawCommand != nil,
            rawAgent != nil,
            rawType != nil
        ].filter(\.self).count
        if definedActionForms > 1 {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "surfaceTabBarButtons entries must define only one of 'action', 'builtin', 'command', 'agent', or 'type'"
                )
            )
        }

        if let rawType {
            switch rawType {
            case "workspaceCommand":
                guard let rawCommandName else {
                    throw DecodingError.dataCorrupted(
                        DecodingError.Context(
                            codingPath: decoder.codingPath,
                            debugDescription: "workspaceCommand surface tab bar buttons require commandName"
                        )
                    )
                }
                action = .workspaceCommand(rawCommandName)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown surface tab bar button type '\(rawType)'"
                )
            }
        } else if let rawCommand {
            action = .command(rawCommand)
        } else if let rawAgent {
            action = .agent(rawAgent, args: rawArgs)
        } else if let rawBuiltin {
            guard let builtIn = CmuxSurfaceTabBarBuiltInAction(configID: rawBuiltin) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .builtin,
                    in: container,
                    debugDescription: "Unknown built-in surface tab bar action '\(rawBuiltin)'"
                )
            }
            action = .builtIn(builtIn)
        } else if let rawAction {
            action = .actionReference(rawAction)
        } else if let explicitId,
                  let builtIn = CmuxSurfaceTabBarBuiltInAction(configID: explicitId) {
            action = .builtIn(builtIn)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "surfaceTabBarButtons entries must define 'action', 'builtin', 'command', 'agent', or 'type'"
                )
            )
        }

        id = explicitId ?? action.defaultId
        title = explicitTitle
        icon = explicitIcon
        tooltip = explicitTooltip
    }

    /// Resolves an action-reference button against the resolved `actions` map,
    /// folding the referenced template (or a matching built-in) into a concrete
    /// button. A non-reference button returns itself unchanged.
    public func resolved(
        actions: [String: CmuxResolvedConfigAction],
        codingPath: [any CodingKey]
    ) throws -> CmuxSurfaceTabBarButton {
        guard case .actionReference(let identifier) = action else {
            return self
        }

        let resolvedIdentifier = CmuxSurfaceTabBarBuiltInAction(configID: identifier)?.configID ?? identifier
        if let definition = actions[resolvedIdentifier] {
            return CmuxSurfaceTabBarButton(
                id: id,
                title: title ?? definition.title,
                icon: icon ?? definition.icon,
                tooltip: tooltip ?? definition.tooltip,
                action: definition.action,
                confirm: confirm ?? definition.confirm,
                terminalCommandTarget: terminalCommandTarget ?? definition.terminalCommandTarget,
                actionSourcePath: definition.actionSourcePath,
                iconSourcePath: icon == nil ? definition.iconSourcePath : iconSourcePath
            )
        }

        if let builtIn = CmuxSurfaceTabBarBuiltInAction(configID: identifier) {
            return CmuxSurfaceTabBarButton(
                id: id,
                title: title,
                icon: icon,
                tooltip: tooltip,
                action: .builtIn(builtIn),
                confirm: confirm,
                terminalCommandTarget: terminalCommandTarget
            )
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Unknown action reference '\(identifier)'"
            )
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encodeIfPresent(tooltip, forKey: .tooltip)
        try container.encodeIfPresent(confirm, forKey: .confirm)
        try container.encodeIfPresent(terminalCommandTarget, forKey: .target)

        switch action {
        case .builtIn(let builtIn):
            try container.encode(builtIn.configID, forKey: .builtin)
        case .command(let command):
            try container.encode(command, forKey: .command)
        case .agent(let agent, let args):
            try container.encode(agent, forKey: .agent)
            try container.encodeIfPresent(args, forKey: .args)
        case .workspaceCommand(let commandName):
            try container.encode("workspaceCommand", forKey: .type)
            try container.encode(commandName, forKey: .commandName)
        case .actionReference(let identifier):
            try container.encode(identifier, forKey: .action)
        }
    }

    private static func trimmedString(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>,
        allowBlankAsNil: Bool = false
    ) throws -> String? {
        guard container.contains(key) else { return nil }
        let raw = try container.decode(String.self, forKey: key)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if allowBlankAsNil { return nil }
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must not be blank"
            )
        }
        return trimmed
    }
}

// MARK: - WorkspaceSurfaceTabBarButtonResolvable

/// Resolution seam for ``WorkspaceSurfaceTabBarButtonResolution``: the executable
/// resolver only needs these four projections to choose a descriptor by
/// precedence, so the concrete button conforms here (co-located with the type).
extension CmuxSurfaceTabBarButton: WorkspaceSurfaceTabBarButtonResolvable {
    public var resolutionID: String { id }
    public var resolutionTerminalCommand: String? { terminalCommand }
    public var resolutionActionSourcePath: String? { actionSourcePath }
    public var resolutionAction: CmuxSurfaceTabBarButtonAction { action }
}
