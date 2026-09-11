import Foundation

/// The kind of extension described by a manifest.
public enum CmuxExtensionKind: String, Codable, Equatable, Sendable {
    /// An ExtensionKit sidebar provider (the original manifest contract).
    case sidebar
    /// A user-installed process-backed plugin.
    case plugin
}

/// Metadata and permission request declared by a CMUX extension or plugin.
public struct CmuxExtensionManifest: Codable, Equatable, Identifiable, Sendable {
    /// Stable reverse-DNS style identifier for the extension.
    public var id: String

    /// Human-readable extension name shown by CMUX permission and management UI.
    public var displayName: String

    /// Minimum CMUX extension API version required by this extension.
    public var minimumAPIVersion: CmuxExtensionAPIVersion

    /// Whether this manifest describes a sidebar provider or a process-backed
    /// plugin. Older sidebar manifests omit the field and decode as `.sidebar`.
    public var kind: CmuxExtensionKind

    /// Sidebar data scopes the extension asks CMUX to include in snapshots.
    public var readScopes: [CmuxExtensionScope]

    /// Host action scopes the extension asks CMUX to allow.
    public var actionScopes: [CmuxExtensionActionScope]

    /// Plugin permission families requested by this manifest.
    public var pluginScopes: [CmuxExtensionPluginScope]

    /// Lifecycle events the plugin wants to receive over `events.stream`.
    public var eventSubscriptions: [CmuxExtensionEvent]

    /// Commands the plugin contributes to the command palette.
    public var actions: [CmuxExtensionAction]

    /// Optional path, relative to the plugin directory, for the executable
    /// that owns the control-socket session.
    public var entrypoint: String?

    /// Creates a sidebar extension manifest.
    public init(
        id: String,
        displayName: String,
        readScopes: [CmuxExtensionScope] = [],
        actionScopes: [CmuxExtensionActionScope] = [],
        minimumAPIVersion: CmuxExtensionAPIVersion = .sidebarV2,
        kind: CmuxExtensionKind = .sidebar,
        pluginScopes: [CmuxExtensionPluginScope] = [],
        eventSubscriptions: [CmuxExtensionEvent] = [],
        actions: [CmuxExtensionAction] = [],
        entrypoint: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.minimumAPIVersion = minimumAPIVersion
        self.kind = kind
        self.readScopes = readScopes
        self.actionScopes = actionScopes
        self.pluginScopes = pluginScopes
        self.eventSubscriptions = eventSubscriptions
        self.actions = actions
        self.entrypoint = entrypoint
    }

    /// Creates a process-backed plugin manifest using the current plugin API.
    public static func plugin(
        id: String,
        displayName: String,
        pluginScopes: [CmuxExtensionPluginScope] = [],
        eventSubscriptions: [CmuxExtensionEvent] = [],
        actions: [CmuxExtensionAction] = [],
        entrypoint: String
    ) -> Self {
        Self(
            id: id,
            displayName: displayName,
            minimumAPIVersion: .pluginV3,
            kind: .plugin,
            pluginScopes: pluginScopes,
            eventSubscriptions: eventSubscriptions,
            actions: actions,
            entrypoint: entrypoint
        )
    }

    /// Plugin permission families explicitly requested by this manifest.
    ///
    /// Event and action declarations do not implicitly elevate this set. The
    /// validator requires callers to name ``CmuxExtensionPluginScope/eventHooks``
    /// or ``CmuxExtensionPluginScope/paletteActions`` explicitly, so a copied
    /// or hand-written manifest always fails closed until the user reviews the
    /// corresponding capability.
    public var requestedPluginScopes: Set<CmuxExtensionPluginScope> {
        Set(pluginScopes)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case display_name
        case minimumAPIVersion
        case minimum_api_version
        case kind
        case type
        case readScopes
        case read_scopes
        case actionScopes
        case action_scopes
        case pluginScopes
        case plugin_scopes
        case eventSubscriptions
        case event_subscriptions
        case eventScopes
        case event_scopes
        case events
        case actions
        case entrypoint
        case executable
    }

    /// Decodes canonical camel-case fields and language-neutral snake-case
    /// aliases while preserving compatibility with versionless sidebar manifests.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        if let value = try container.decodeIfPresent(String.self, forKey: .displayName) {
            displayName = value
        } else {
            displayName = try container.decode(String.self, forKey: .display_name)
        }
        readScopes = try container.decodeIfPresent([CmuxExtensionScope].self, forKey: .readScopes) ?? []
        if readScopes.isEmpty {
            readScopes = try container.decodeIfPresent([CmuxExtensionScope].self, forKey: .read_scopes) ?? []
        }
        actionScopes = try container.decodeIfPresent(
            [CmuxExtensionActionScope].self,
            forKey: .actionScopes
        ) ?? []
        if actionScopes.isEmpty {
            actionScopes = try container.decodeIfPresent(
                [CmuxExtensionActionScope].self,
                forKey: .action_scopes
            ) ?? []
        }
        if let value = try container.decodeIfPresent([CmuxExtensionPluginScope].self, forKey: .pluginScopes) {
            pluginScopes = value
        } else {
            pluginScopes = try container.decodeIfPresent([CmuxExtensionPluginScope].self, forKey: .plugin_scopes) ?? []
        }
        if let value = try container.decodeIfPresent([CmuxExtensionEvent].self, forKey: .eventSubscriptions) {
            eventSubscriptions = value
        } else if let value = try container.decodeIfPresent([CmuxExtensionEvent].self, forKey: .event_subscriptions) {
            eventSubscriptions = value
        } else if let value = try container.decodeIfPresent([CmuxExtensionEvent].self, forKey: .eventScopes) {
            eventSubscriptions = value
        } else if let value = try container.decodeIfPresent([CmuxExtensionEvent].self, forKey: .event_scopes) {
            eventSubscriptions = value
        } else {
            eventSubscriptions = try container.decodeIfPresent([CmuxExtensionEvent].self, forKey: .events) ?? []
        }
        actions = try container.decodeIfPresent([CmuxExtensionAction].self, forKey: .actions) ?? []
        if let value = try container.decodeIfPresent(String.self, forKey: .entrypoint) {
            entrypoint = value
        } else {
            entrypoint = try container.decodeIfPresent(String.self, forKey: .executable)
        }

        if let rawKind = try container.decodeIfPresent(CmuxExtensionKind.self, forKey: .kind) {
            kind = rawKind
        } else if let rawKind = try container.decodeIfPresent(CmuxExtensionKind.self, forKey: .type) {
            kind = rawKind
        } else {
            kind = (pluginScopes.isEmpty && eventSubscriptions.isEmpty && actions.isEmpty && entrypoint == nil)
                ? .sidebar
                : .plugin
        }

        // Sidebar manifests historically omitted this field because the host
        // supplied the API version. Process-backed plugins use their own API
        // family, so an explicitly plugin-shaped manifest without a version
        // must not accidentally fail closed as a sidebar-v2 request.
        if let value = try container.decodeIfPresent(CmuxExtensionAPIVersion.self, forKey: .minimumAPIVersion) {
            minimumAPIVersion = value
        } else if let value = try container.decodeIfPresent(CmuxExtensionAPIVersion.self, forKey: .minimum_api_version) {
            minimumAPIVersion = value
        } else {
            minimumAPIVersion = kind == .plugin ? .pluginV3 : .sidebarV2
        }
    }

    /// Encodes the canonical camel-case manifest representation.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(minimumAPIVersion, forKey: .minimumAPIVersion)
        if kind != .sidebar { try container.encode(kind, forKey: .kind) }
        // Older sidebar hosts require both array keys even when they are empty.
        try container.encode(readScopes, forKey: .readScopes)
        try container.encode(actionScopes, forKey: .actionScopes)
        if !pluginScopes.isEmpty { try container.encode(pluginScopes, forKey: .pluginScopes) }
        if !eventSubscriptions.isEmpty { try container.encode(eventSubscriptions, forKey: .eventSubscriptions) }
        if !actions.isEmpty { try container.encode(actions, forKey: .actions) }
        try container.encodeIfPresent(entrypoint, forKey: .entrypoint)
    }
}
