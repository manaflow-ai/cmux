import AppKit

struct CmuxConfigUIDefinition: Codable, Sendable, Hashable {
    var newWorkspace: CmuxConfigButtonPlacement?
    var surfaceTabBar: CmuxSurfaceTabBarUIDefinition?
}

struct CmuxSurfaceTabBarUIDefinition: Codable, Sendable, Hashable {
    var buttons: [CmuxSurfaceTabBarButton]?
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
