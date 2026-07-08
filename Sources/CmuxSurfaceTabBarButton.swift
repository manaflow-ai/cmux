import Bonsplit
import Foundation

struct CmuxSurfaceTabBarButton: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var title: String?
    var icon: CmuxButtonIcon?
    var tooltip: String?
    var action: CmuxSurfaceTabBarButtonAction
    var menu: [CmuxSurfaceTabBarMenuItem]?
    var confirm: Bool?
    var terminalCommandTarget: CmuxConfigTerminalCommandTarget?
    var actionSourcePath: String?
    var iconSourcePath: String?

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
        case workspace
        case restart
        case menu
        case items
        case confirm
        case target
    }

    static let newTerminal = actionReference(CmuxSurfaceTabBarBuiltInAction.newTerminal.configID)
    static let newBrowser = actionReference(CmuxSurfaceTabBarBuiltInAction.newBrowser.configID)
    static let splitRight = actionReference(CmuxSurfaceTabBarBuiltInAction.splitRight.configID)
    static let splitDown = actionReference(CmuxSurfaceTabBarBuiltInAction.splitDown.configID)
    static let more = actionReference(CmuxSurfaceTabBarBuiltInAction.more.configID)
    static let mobileConnect = actionReference(CmuxSurfaceTabBarBuiltInAction.mobileConnect.configID)

    static let defaultMoreMenu: [CmuxSurfaceTabBarMenuItem] = [
        .actionReference(CmuxSurfaceTabBarBuiltInAction.diffViewer.configID),
        .actionReference(CmuxSurfaceTabBarBuiltInAction.filesPane.configID),
        .actionReference(CmuxSurfaceTabBarBuiltInAction.findPane.configID),
        .actionReference(CmuxSurfaceTabBarBuiltInAction.vaultPane.configID),
        .actionReference(CmuxSurfaceTabBarBuiltInAction.rightSidebarNotes.configID),
    ]

    static let defaults: [CmuxSurfaceTabBarButton] = [
        .newTerminal,
        .newBrowser,
        .splitRight,
        .splitDown,
        .more
    ]

    static func builtIn(
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
            menu: nil,
            confirm: nil,
            terminalCommandTarget: nil
        )
    }

    static func actionReference(
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
            action: .actionReference(actionID),
            menu: nil
        )
    }

    var command: String? {
        action.terminalCommand
    }

    var terminalCommand: String? {
        action.terminalCommand
    }

    var resolvedTerminalCommandTarget: CmuxConfigTerminalCommandTarget {
        terminalCommandTarget ?? CmuxConfigTerminalCommandTarget.defaultForActions
    }

    var workspaceCommandName: String? {
        action.workspaceCommandName
    }

    /// Synthetic named command for inline `type: "workspace"` buttons/actions so
    /// execution and trust fingerprinting share one definition. Carries the
    /// button's `confirm` so explicit confirmation requests survive the wrap.
    var inlineWorkspaceSyntheticCommand: CmuxCommandDefinition? {
        guard let inline = action.inlineWorkspace else { return nil }
        return CmuxCommandDefinition(
            name: title ?? tooltip ?? inline.definition.name ?? id,
            restart: inline.restart,
            workspace: inline.definition,
            confirm: confirm
        )
    }

    func bonsplitActionButton(
        configSourcePath: String?,
        globalConfigPath: String,
        allowProjectLocalIcon: Bool = true
    ) -> BonsplitConfiguration.SplitActionButton {
        let bonsplitAction: BonsplitConfiguration.SplitActionButton.Action = {
            if menu != nil {
                return .custom(id)
            }
            switch action {
            case .builtIn(let builtIn):
                return builtIn.bonsplitAction ?? .custom(id)
            case .command, .agent, .workspaceCommand, .workspace, .actionReference:
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
            action: bonsplitAction,
            activatesOnMouseDown: menu != nil || action.isBuiltInMoreReference
        )
    }

    init(
        id: String,
        title: String? = nil,
        icon: CmuxButtonIcon? = nil,
        tooltip: String? = nil,
        action: CmuxSurfaceTabBarButtonAction,
        menu: [CmuxSurfaceTabBarMenuItem]? = nil,
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
        self.menu = menu
        self.confirm = confirm
        self.terminalCommandTarget = terminalCommandTarget
        self.actionSourcePath = actionSourcePath
        self.iconSourcePath = iconSourcePath
    }

    init(from decoder: Decoder) throws {
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
        let decodedMenu = try container.decodeIfPresent([CmuxSurfaceTabBarMenuItem].self, forKey: .menu)
            ?? container.decodeIfPresent([CmuxSurfaceTabBarMenuItem].self, forKey: .items)
        confirm = try container.decodeIfPresent(Bool.self, forKey: .confirm)
        terminalCommandTarget = try container.decodeIfPresent(CmuxConfigTerminalCommandTarget.self, forKey: .target)
        actionSourcePath = nil
        iconSourcePath = nil
        menu = decodedMenu

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
            case "menu":
                action = .builtIn(.more)
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
            case "workspace":
                guard container.contains(.workspace) else {
                    throw DecodingError.dataCorrupted(
                        DecodingError.Context(
                            codingPath: decoder.codingPath,
                            debugDescription: "workspace surface tab bar buttons require a 'workspace' object"
                        )
                    )
                }
                let definition = try container.decode(CmuxWorkspaceDefinition.self, forKey: .workspace)
                let restart = try container.decodeIfPresent(CmuxRestartBehavior.self, forKey: .restart)
                action = .workspace(definition, restart: restart)
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
        } else if decodedMenu != nil {
            action = .builtIn(.more)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "surfaceTabBarButtons entries must define 'action', 'builtin', 'command', 'agent', 'menu', or 'type'"
                )
            )
        }

        id = explicitId ?? action.defaultId
        title = explicitTitle
        icon = explicitIcon
        tooltip = explicitTooltip
    }

    func resolved(
        actions: [String: CmuxResolvedConfigAction],
        codingPath: [CodingKey]
    ) throws -> CmuxSurfaceTabBarButton {
        let resolvedMenu = try resolvedMenu(actions: actions, codingPath: codingPath)
        guard case .actionReference(let identifier) = action else {
            var resolved = self
            resolved.menu = resolvedMenu
            return resolved
        }

        let resolvedIdentifier = CmuxSurfaceTabBarBuiltInAction(configID: identifier)?.configID ?? identifier
        if let definition = actions[resolvedIdentifier] {
            return CmuxSurfaceTabBarButton(
                id: id,
                title: title ?? definition.title,
                icon: icon ?? definition.icon,
                tooltip: tooltip ?? definition.tooltip,
                action: definition.action,
                menu: resolvedMenu,
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
                menu: resolvedMenu,
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

    func resolvedMenu(
        actions: [String: CmuxResolvedConfigAction],
        codingPath: [CodingKey]
    ) throws -> [CmuxSurfaceTabBarMenuItem]? {
        let menuButtons: [CmuxSurfaceTabBarMenuItem]?
        if let menu {
            menuButtons = menu
        } else if action.isBuiltInMoreReference {
            menuButtons = Self.defaultMoreMenu
        } else {
            menuButtons = nil
        }
        guard let menuButtons else { return nil }
        return try menuButtons.enumerated().map { index, button in
            let resolvedButton = try button.button.resolved(
                actions: actions,
                codingPath: codingPath + [CmuxSurfaceTabBarMenuCodingKey(index: index)]
            )
            return CmuxSurfaceTabBarMenuItem(resolvedButton)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encodeIfPresent(tooltip, forKey: .tooltip)
        try container.encodeIfPresent(menu, forKey: .menu)
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
        case .workspace(let definition, let restart):
            try container.encode("workspace", forKey: .type)
            try container.encode(definition, forKey: .workspace)
            try container.encodeIfPresent(restart, forKey: .restart)
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
