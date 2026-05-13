import AppKit

struct CmuxConfigUIDefinition: Codable, Sendable, Hashable {
    var newWorkspace: CmuxConfigButtonPlacement?
    var surfaceTabBar: CmuxSurfaceTabBarUIDefinition?
    var menuBar: CmuxMenuBarUIDefinition?
}

struct CmuxSurfaceTabBarUIDefinition: Codable, Sendable, Hashable {
    var buttons: [CmuxSurfaceTabBarButton]?
}

struct CmuxMenuBarUIDefinition: Codable, Sendable, Hashable {
    var menus: [CmuxConfigMenuDefinition]

    private enum CodingKeys: String, CodingKey {
        case menus
    }

    init(menus: [CmuxConfigMenuDefinition] = []) {
        self.menus = menus
    }

    init(from decoder: Decoder) throws {
        if let menus = try? decoder.singleValueContainer().decode([CmuxConfigMenuDefinition].self) {
            self.menus = menus
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        menus = try container.decodeIfPresent([CmuxConfigMenuDefinition].self, forKey: .menus) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(menus, forKey: .menus)
    }
}

struct CmuxConfigMenuDefinition: Codable, Sendable, Hashable {
    var id: String?
    var title: String
    var items: [CmuxConfigMenuBarItem]

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case items
    }

    init(id: String? = nil, title: String, items: [CmuxConfigMenuBarItem] = []) {
        self.id = id
        self.title = title
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try Self.trimmedString(forKey: .id, in: container, allowBlankAsNil: true)
        title = try Self.requiredTrimmedString(forKey: .title, in: container)
        items = try container.decodeIfPresent([CmuxConfigMenuBarItem].self, forKey: .items) ?? []
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
}

struct CmuxConfigMenuBarActionItem: Codable, Sendable, Hashable {
    var action: String?
    var inlineAction: CmuxConfigActionDefinition?
    var title: String?
    var icon: CmuxButtonIcon?
    var tooltip: String?

    private enum CodingKeys: String, CodingKey {
        case action
        case title
        case icon
        case tooltip
        case type
        case builtin
        case command
        case commandName
        case name
        case agent
        case args
        case subtitle
        case description
        case keywords
        case palette
        case shortcut
        case confirm
        case target
    }

    init(
        action: String,
        title: String? = nil,
        icon: CmuxButtonIcon? = nil,
        tooltip: String? = nil
    ) {
        self.action = action
        self.inlineAction = nil
        self.title = title
        self.icon = icon
        self.tooltip = tooltip
    }

    init(
        inlineAction: CmuxConfigActionDefinition,
        title: String? = nil,
        icon: CmuxButtonIcon? = nil,
        tooltip: String? = nil
    ) {
        self.action = nil
        self.inlineAction = inlineAction
        self.title = title
        self.icon = icon
        self.tooltip = tooltip
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try Self.trimmedString(forKey: .title, in: container, allowBlankAsNil: true)
        icon = try container.decodeIfPresent(CmuxButtonIcon.self, forKey: .icon)
        tooltip = try Self.trimmedString(forKey: .tooltip, in: container, allowBlankAsNil: true)

        let actionReference = try Self.trimmedString(forKey: .action, in: container)
        let hasInlineAction = [
            container.contains(.type),
            container.contains(.builtin),
            container.contains(.command),
            container.contains(.commandName),
            container.contains(.agent)
        ].contains(true)

        if actionReference != nil && hasInlineAction {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "menuBar items must define either 'action' or an inline action, not both"
                )
            )
        }

        if let actionReference {
            action = actionReference
            inlineAction = nil
            return
        }

        if hasInlineAction {
            let definition = try CmuxConfigActionDefinition(from: decoder)
            guard definition.action != nil else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "menuBar inline actions must be runnable"
                    )
                )
            }
            action = nil
            inlineAction = definition
            return
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "menuBar action items must define 'action', 'command', 'agent', 'builtin', or 'type'"
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        if let action {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(action, forKey: .action)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encodeIfPresent(icon, forKey: .icon)
            try container.encodeIfPresent(tooltip, forKey: .tooltip)
            return
        }

        try inlineAction?.encode(to: encoder)
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

indirect enum CmuxConfigMenuBarItem: Codable, Sendable, Hashable {
    case action(CmuxConfigMenuBarActionItem)
    case submenu(CmuxConfigMenuDefinition)
    case separator

    private enum CodingKeys: String, CodingKey {
        case type
        case title
        case items
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let rawAction = try? container.decode(String.self) {
            let trimmed = rawAction.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "-" || trimmed == "separator" {
                self = .separator
                return
            }
            guard !trimmed.isEmpty else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "menuBar action must not be blank"
                    )
                )
            }
            self = .action(CmuxConfigMenuBarActionItem(action: trimmed))
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try Self.trimmedString(forKey: .type, in: container)
        if rawType == "separator" {
            self = .separator
            return
        }
        if container.contains(.items) || rawType == "menu" || rawType == "submenu" {
            self = .submenu(try CmuxConfigMenuDefinition(from: decoder))
            return
        }
        self = .action(try CmuxConfigMenuBarActionItem(from: decoder))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .action(let item):
            try item.encode(to: encoder)
        case .submenu(let menu):
            try menu.encode(to: encoder)
        case .separator:
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("separator", forKey: .type)
        }
    }

    private static func trimmedString(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String? {
        guard container.contains(key) else { return nil }
        let raw = try container.decode(String.self, forKey: key)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must not be blank"
            )
        }
        return trimmed
    }
}

struct CmuxConfigButtonPlacement: Codable, Sendable, Hashable {
    var action: String?
    var icon: CmuxButtonIcon?
    var tooltip: String?
    var contextMenu: [CmuxConfigContextMenuItem]?

    private enum CodingKeys: String, CodingKey {
        case action
        case icon
        case tooltip
        case contextMenu
        case rightClick
    }

    init(
        action: String? = nil,
        icon: CmuxButtonIcon? = nil,
        tooltip: String? = nil,
        contextMenu: [CmuxConfigContextMenuItem]? = nil
    ) {
        self.action = action
        self.icon = icon
        self.tooltip = tooltip
        self.contextMenu = contextMenu
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try Self.trimmedString(forKey: .action, in: container)
        icon = try container.decodeIfPresent(CmuxButtonIcon.self, forKey: .icon)
        tooltip = try Self.trimmedString(forKey: .tooltip, in: container, allowBlankAsNil: true)
        contextMenu = try container.decodeIfPresent([CmuxConfigContextMenuItem].self, forKey: .contextMenu)
            ?? container.decodeIfPresent([CmuxConfigContextMenuItem].self, forKey: .rightClick)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(action, forKey: .action)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encodeIfPresent(tooltip, forKey: .tooltip)
        try container.encodeIfPresent(contextMenu, forKey: .contextMenu)
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

struct CmuxConfigContextMenuActionItem: Codable, Sendable, Hashable {
    var action: String
    var title: String?
    var icon: CmuxButtonIcon?
    var tooltip: String?

    private enum CodingKeys: String, CodingKey {
        case action
        case title
        case icon
        case tooltip
    }

    init(action: String, title: String? = nil, icon: CmuxButtonIcon? = nil, tooltip: String? = nil) {
        self.action = action
        self.title = title
        self.icon = icon
        self.tooltip = tooltip
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try Self.requiredTrimmedString(forKey: .action, in: container)
        title = try Self.trimmedString(forKey: .title, in: container, allowBlankAsNil: true)
        icon = try container.decodeIfPresent(CmuxButtonIcon.self, forKey: .icon)
        tooltip = try Self.trimmedString(forKey: .tooltip, in: container, allowBlankAsNil: true)
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
}

enum CmuxConfigContextMenuItem: Codable, Sendable, Hashable {
    case action(CmuxConfigContextMenuActionItem)
    case separator

    private enum CodingKeys: String, CodingKey {
        case type
        case action
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let rawAction = try? container.decode(String.self) {
            let trimmed = rawAction.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "-" || trimmed == "separator" {
                self = .separator
                return
            }
            guard !trimmed.isEmpty else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "contextMenu action must not be blank"
                    )
                )
            }
            self = .action(CmuxConfigContextMenuActionItem(action: trimmed))
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try Self.trimmedString(forKey: .type, in: container)
        if rawType == "separator" {
            self = .separator
            return
        }
        self = .action(try CmuxConfigContextMenuActionItem(from: decoder))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .action(let item):
            try item.encode(to: encoder)
        case .separator:
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("separator", forKey: .type)
        }
    }

    private static func trimmedString(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String? {
        guard container.contains(key) else { return nil }
        let raw = try container.decode(String.self, forKey: key)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must not be blank"
            )
        }
        return trimmed
    }
}

struct CmuxResolvedConfigMenuAction: Identifiable, Sendable, Hashable {
    var id: String
    var title: String
    var icon: CmuxButtonIcon?
    var tooltip: String?
    var action: CmuxResolvedConfigAction
}

enum CmuxResolvedConfigContextMenuItem: Identifiable, Sendable, Hashable {
    case action(CmuxResolvedConfigMenuAction)
    case separator(id: String)

    var id: String {
        switch self {
        case .action(let action):
            return action.id
        case .separator(let id):
            return id
        }
    }
}

struct CmuxResolvedMenuBarMenu: Identifiable, Sendable, Hashable {
    var id: String
    var title: String
    var items: [CmuxResolvedMenuBarItem]
}

indirect enum CmuxResolvedMenuBarItem: Identifiable, Sendable, Hashable {
    case action(CmuxResolvedConfigMenuAction)
    case submenu(CmuxResolvedMenuBarMenu)
    case separator(id: String)

    var id: String {
        switch self {
        case .action(let action):
            return action.id
        case .submenu(let menu):
            return menu.id
        case .separator(let id):
            return id
        }
    }
}

enum CmuxRestartBehavior: String, Codable, Sendable {
    case new
    case recreate
    case ignore
    case confirm
}

extension CmuxButtonIcon {
    var sfSymbolImage: NSImage? {
        guard case .symbol(let symbolName) = self else {
#if DEBUG
            assertionFailure("cmux config menu icons only support SF Symbols")
#endif
            return nil
        }
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    }
}
