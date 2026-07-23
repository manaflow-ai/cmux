import Foundation

struct CmuxConfigActionDefinition: Codable, Sendable, Hashable {
    var action: CmuxSurfaceTabBarButtonAction?
    var title: String?
    var subtitle: String?
    var keywords: [String]?
    var palette: Bool?
    var shortcut: StoredShortcut?
    var icon: CmuxButtonIcon?
    var tooltip: String?
    var confirm: Bool?
    var terminalCommandTarget: CmuxConfigTerminalCommandTarget?
    /// Whether this action is offered in the new-workspace plus-button menu.
    /// Defaults to true for `workspace` actions and false otherwise.
    var newWorkspaceMenu: Bool?
    /// Whether this action is offered in the terminal right-click context
    /// menu. Defaults to false.
    var terminalContextMenu: Bool?

    private enum CodingKeys: String, CodingKey {
        case type
        case builtin
        case command
        case commandName
        case name
        case agent
        case args
        case workspace
        case restart
        case title
        case subtitle
        case description
        case keywords
        case palette
        case shortcut
        case icon
        case tooltip
        case confirm
        case target
        case newWorkspaceMenu
        case terminalContextMenu
    }

    init(
        action: CmuxSurfaceTabBarButtonAction? = nil,
        title: String? = nil,
        subtitle: String? = nil,
        keywords: [String]? = nil,
        palette: Bool? = nil,
        shortcut: StoredShortcut? = nil,
        icon: CmuxButtonIcon? = nil,
        tooltip: String? = nil,
        confirm: Bool? = nil,
        terminalCommandTarget: CmuxConfigTerminalCommandTarget? = nil,
        newWorkspaceMenu: Bool? = nil,
        terminalContextMenu: Bool? = nil
    ) {
        self.action = action
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.palette = palette
        self.shortcut = shortcut
        self.icon = icon
        self.tooltip = tooltip
        self.confirm = confirm
        self.terminalCommandTarget = terminalCommandTarget
        self.newWorkspaceMenu = newWorkspaceMenu
        self.terminalContextMenu = terminalContextMenu
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try Self.trimmedString(forKey: .type, in: container)
        title = try Self.trimmedString(forKey: .title, in: container, allowBlankAsNil: true)
        subtitle = try Self.trimmedString(forKey: .subtitle, in: container, allowBlankAsNil: true)
            ?? Self.trimmedString(forKey: .description, in: container, allowBlankAsNil: true)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords)?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        palette = try container.decodeIfPresent(Bool.self, forKey: .palette)
        shortcut = try Self.decodeShortcut(forKey: .shortcut, in: container)
        icon = try container.decodeIfPresent(CmuxButtonIcon.self, forKey: .icon)
        tooltip = try Self.trimmedString(forKey: .tooltip, in: container, allowBlankAsNil: true)
        confirm = try container.decodeIfPresent(Bool.self, forKey: .confirm)
        terminalCommandTarget = try container.decodeIfPresent(CmuxConfigTerminalCommandTarget.self, forKey: .target)
        newWorkspaceMenu = try container.decodeIfPresent(Bool.self, forKey: .newWorkspaceMenu)
        terminalContextMenu = try container.decodeIfPresent(Bool.self, forKey: .terminalContextMenu)

        let inferredType: String?
        if let type {
            inferredType = type
        } else if container.contains(.agent) {
            inferredType = "agent"
        } else if container.contains(.builtin) {
            inferredType = "builtin"
        } else if container.contains(.workspace) {
            inferredType = "workspace"
        } else if container.contains(.command) {
            inferredType = "command"
        } else {
            inferredType = nil
        }

        switch inferredType {
        case "builtin":
            let raw = try Self.trimmedString(forKey: .builtin, in: container) ?? ""
            guard let builtIn = CmuxSurfaceTabBarBuiltInAction(configID: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .builtin,
                    in: container,
                    debugDescription: "Unknown built-in action '\(raw)'"
                )
            }
            action = .builtIn(builtIn)
        case "command":
            let command = try Self.requiredTrimmedString(forKey: .command, in: container)
            action = .command(command)
        case "agent":
            let agent = try container.decode(CmuxConfigAgentKind.self, forKey: .agent)
            let args = try Self.trimmedString(forKey: .args, in: container, allowBlankAsNil: true)
            action = .agent(agent, args: args)
        case "workspaceCommand":
            let commandName = try Self.trimmedString(forKey: .commandName, in: container)
                ?? Self.trimmedString(forKey: .name, in: container)
                ?? Self.trimmedString(forKey: .command, in: container)
            guard let commandName else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "workspaceCommand actions require commandName"
                    )
                )
            }
            action = .workspaceCommand(commandName)
        case "workspace":
            guard container.contains(.workspace) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "workspace actions require a 'workspace' object"
                    )
                )
            }
            let definition = try container.decode(CmuxWorkspaceDefinition.self, forKey: .workspace)
            let restart = try container.decodeIfPresent(CmuxRestartBehavior.self, forKey: .restart)
            action = .workspace(definition, restart: restart)
        case nil:
            action = nil
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown action type '\(inferredType ?? "")'"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
        try container.encodeIfPresent(keywords, forKey: .keywords)
        try container.encodeIfPresent(palette, forKey: .palette)
        try Self.encodeShortcut(shortcut, forKey: .shortcut, in: &container)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encodeIfPresent(tooltip, forKey: .tooltip)
        try container.encodeIfPresent(confirm, forKey: .confirm)
        try container.encodeIfPresent(terminalCommandTarget, forKey: .target)
        try container.encodeIfPresent(newWorkspaceMenu, forKey: .newWorkspaceMenu)
        try container.encodeIfPresent(terminalContextMenu, forKey: .terminalContextMenu)
        guard let action else { return }
        switch action {
        case .builtIn(let builtIn):
            try container.encode("builtin", forKey: .type)
            try container.encode(builtIn.configID, forKey: .builtin)
        case .command(let command):
            try container.encode("command", forKey: .type)
            try container.encode(command, forKey: .command)
        case .agent(let agent, let args):
            try container.encode("agent", forKey: .type)
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
            try container.encode("builtin", forKey: .type)
            try container.encode(identifier, forKey: .builtin)
        }
    }

    private static func requiredTrimmedString(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String {
        guard let value = try trimmedString(forKey: key, in: container) else {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "\(key.stringValue) is required"
                )
            )
        }
        return value
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

    private static func decodeShortcut(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> StoredShortcut? {
        guard container.contains(key) else { return nil }
        if let rawShortcut = try? container.decode(String.self, forKey: key) {
            guard let shortcut = StoredShortcut.parseConfig(rawShortcut) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "shortcut must use modifier+key syntax like 'cmd+shift+t' or be empty to unbind"
                )
            }
            return shortcut
        }
        if let rawShortcut = try? container.decode([String].self, forKey: key) {
            guard let shortcut = StoredShortcut.parseConfig(strokes: rawShortcut) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "shortcut chords must be one or two non-empty strokes"
                )
            }
            return shortcut
        }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: container,
            debugDescription: "shortcut must be a string or array of one or two strings"
        )
    }

    private static func encodeShortcut(
        _ shortcut: StoredShortcut?,
        forKey key: CodingKeys,
        in container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        guard let shortcut else { return }
        if shortcut.isUnbound {
            try container.encode("", forKey: key)
            return
        }
        if let secondStroke = shortcut.secondStroke {
            try container.encode(
                [shortcut.firstStroke.configString(), secondStroke.configString()],
                forKey: key
            )
        } else {
            try container.encode(shortcut.firstStroke.configString(), forKey: key)
        }
    }
}
