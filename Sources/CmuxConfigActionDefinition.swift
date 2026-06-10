import Bonsplit
import CmuxFileWatch
import Combine
import CryptoKit
import Foundation


// MARK: - Action Definitions
enum CmuxConfigTerminalCommandTarget: String, Codable, Sendable, Hashable {
    case currentTerminal
    case newTabInCurrentPane

    static let defaultForActions: CmuxConfigTerminalCommandTarget = .newTabInCurrentPane
}

enum CmuxConfigAgentKind: Sendable, Hashable {
    case codex
    case claudeCode

    var commandName: String {
        switch self {
        case .codex:
            return "codex"
        case .claudeCode:
            return "claude"
        }
    }

    var defaultIcon: CmuxButtonIcon {
        switch self {
        case .codex:
            return .symbol("sparkles")
        case .claudeCode:
            return .symbol("brain.head.profile")
        }
    }
}

extension CmuxConfigAgentKind: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "codex":
            self = .codex
        case "claude", "claudeCode", "claude-code":
            self = .claudeCode
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown agent '\(value)'"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .codex:
            try container.encode("codex")
        case .claudeCode:
            try container.encode("claude")
        }
    }
}

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

    private enum CodingKeys: String, CodingKey {
        case type
        case builtin
        case command
        case commandName
        case name
        case agent
        case args
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
        terminalCommandTarget: CmuxConfigTerminalCommandTarget? = nil
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

        let inferredType: String?
        if let type {
            inferredType = type
        } else if container.contains(.agent) {
            inferredType = "agent"
        } else if container.contains(.builtin) {
            inferredType = "builtin"
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

struct CmuxResolvedConfigAction: Identifiable, Sendable, Hashable {
    var id: String
    var title: String
    var subtitle: String?
    var keywords: [String]
    var palette: Bool
    var shortcut: StoredShortcut?
    var icon: CmuxButtonIcon?
    var tooltip: String?
    var action: CmuxSurfaceTabBarButtonAction
    var confirm: Bool?
    var terminalCommandTarget: CmuxConfigTerminalCommandTarget?
    var actionSourcePath: String?
    var iconSourcePath: String?

    var terminalCommand: String? {
        action.terminalCommand
    }

    var workspaceCommandName: String? {
        action.workspaceCommandName
    }

    func applying(
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

    static func fromDefinition(
        id: String,
        definition: CmuxConfigActionDefinition,
        sourcePath: String?
    ) -> CmuxResolvedConfigAction? {
        guard let action = definition.action else { return nil }
        let title = definition.title
            ?? definition.tooltip
            ?? Self.defaultTitle(for: id, action: action)
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

    static func builtIn(_ builtIn: CmuxSurfaceTabBarBuiltInAction) -> CmuxResolvedConfigAction {
        let title: String
        let keywords: [String]
        switch builtIn {
        case .newWorkspace:
            title = String(localized: "command.newWorkspace.title", defaultValue: "New Workspace")
            keywords = ["create", "new", "workspace"]
        case .cloudVM:
            title = String(localized: "command.cloudVM.title", defaultValue: "Start Cloud VM")
            keywords = ["cloud", "vm", "virtual", "machine", "remote"]
        case .newTerminal:
            title = String(localized: "command.newTerminalTab.title", defaultValue: "New Terminal Tab")
            keywords = ["new", "terminal", "tab", "surface"]
        case .newBrowser:
            title = String(localized: "command.newBrowserTab.title", defaultValue: "New Browser Tab")
            keywords = ["new", "browser", "tab", "surface"]
        case .splitRight:
            title = String(localized: "command.terminalSplitRight.title", defaultValue: "Split Right")
            keywords = ["terminal", "split", "right"]
        case .splitDown:
            title = String(localized: "command.terminalSplitDown.title", defaultValue: "Split Down")
            keywords = ["terminal", "split", "down"]
        }

        return CmuxResolvedConfigAction(
            id: builtIn.configID,
            title: title,
            subtitle: String(localized: "command.cmuxConfig.builtInSubtitle", defaultValue: "cmux"),
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

    private static func defaultTitle(for id: String, action: CmuxSurfaceTabBarButtonAction) -> String {
        switch action {
        case .agent(let agent, _):
            switch agent {
            case .codex:
                return String(localized: "command.cmuxConfig.defaultCodexTitle", defaultValue: "Codex")
            case .claudeCode:
                return String(localized: "command.cmuxConfig.defaultClaudeCodeTitle", defaultValue: "Claude Code")
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

