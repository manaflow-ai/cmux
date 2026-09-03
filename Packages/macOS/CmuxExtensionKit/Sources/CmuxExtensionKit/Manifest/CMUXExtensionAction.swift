import Foundation

/// A command declared by a process-backed plugin.
///
/// The declaration is intentionally data-only. The plugin owns execution and
/// receives an invocation over the control-socket event stream; cmux keeps the
/// palette contribution separate from any language-specific plugin runtime.
public struct CmuxExtensionAction: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Plugin-local action identifier. The host namespaces it as
    /// `plugin.<plugin-id>.<action-id>`.
    public var id: String
    /// User-visible command title.
    public var title: String
    /// Optional secondary text shown below the title in the palette.
    public var subtitle: String?
    /// Additional terms used by command-palette search.
    public var keywords: [String]
    /// Optional default shortcut in cmux's human-readable key format.
    ///
    /// A default is only a hint. The user's binding is persisted separately
    /// and always wins over this value.
    public var defaultShortcut: String?

    /// Creates an action declaration.
    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        keywords: [String] = [],
        defaultShortcut: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.defaultShortcut = defaultShortcut
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case subtitle
        case keywords
        case defaultShortcut
        case default_shortcut
    }

    /// Decodes both the camel-case SDK spelling and the snake-case spelling
    /// used by language-neutral plugin manifests.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        if let value = try container.decodeIfPresent(String.self, forKey: .defaultShortcut) {
            defaultShortcut = value
        } else {
            defaultShortcut = try container.decodeIfPresent(String.self, forKey: .default_shortcut)
        }
    }

    /// Encodes the canonical camel-case manifest spelling.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
        if !keywords.isEmpty { try container.encode(keywords, forKey: .keywords) }
        try container.encodeIfPresent(defaultShortcut, forKey: .defaultShortcut)
    }
}

/// A plugin action identifier after host namespacing.
public struct CmuxExtensionActionID: Hashable, Codable, Sendable, CustomStringConvertible {
    /// The plugin's stable identifier.
    public let pluginID: String
    /// The plugin-local action identifier.
    public let actionID: String

    /// Creates a namespaced action identifier.
    public init(pluginID: String, actionID: String) {
        self.pluginID = pluginID
        self.actionID = actionID
    }

    /// Stable command-palette/configuration identifier.
    public var rawValue: String { "plugin.\(pluginID).\(actionID)" }

    /// The same stable namespaced value used by ``rawValue``.
    public var description: String { rawValue }
}
