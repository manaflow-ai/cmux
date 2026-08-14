import Foundation

/// Sidebar snapshot data that an extension may request from the host.
public enum CmuxExtensionScope: String, Codable, CaseIterable, Equatable, Sendable {
    /// Workspace identity and ordering.
    case workspaceList
    /// Workspace titles, detail text, selection, and unread state.
    case workspaceMetadata
    /// Surface identity, kind, and selection metadata.
    case surfaceMetadata
    /// Workspace and surface working-directory paths.
    case workspacePaths
    /// Notification summaries associated with workspaces and surfaces.
    case notifications
    /// Detected local listening ports.
    case networkPorts
    /// Pull-request metadata associated with a workspace.
    case pullRequests

    /// Decodes camel-case, snake-case, or kebab-case scope spellings.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let normalized = Self.normalize(raw)
        guard let value = Self.allCases.first(where: { Self.normalize($0.rawValue) == normalized }) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unknown CMUX extension read scope: \(raw)"
            )
        }
        self = value
    }

    /// Encodes the canonical camel-case scope spelling.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func normalize(_ value: String) -> String {
        value
            .filter { $0 != "_" && $0 != "-" }
            .lowercased()
    }
}

/// Host mutations that a sidebar extension may request.
public enum CmuxExtensionActionScope: String, Codable, CaseIterable, Equatable, Sendable {
    /// Create an empty workspace.
    case createWorkspace
    /// Select an existing workspace.
    case selectWorkspace
    /// Close an existing workspace.
    case closeWorkspace
    /// Create a surface in an existing workspace.
    case createSurface
    /// Select an existing surface.
    case selectSurface
    /// Close an existing surface.
    case closeSurface
    /// Split an existing surface into a new pane.
    case splitSurface
    /// Toggle a surface's zoomed state.
    case zoomSurface
    /// Select an adjacent workspace.
    case navigateWorkspace
    /// Select an adjacent surface.
    case navigateSurface
    /// Open a URL through the host.
    case openURL
    /// Create a workspace rooted at a requested path.
    case createWorkspaceWithPath

    /// Decodes camel-case, snake-case, or kebab-case scope spellings.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let normalized = Self.normalize(raw)
        guard let value = Self.allCases.first(where: { Self.normalize($0.rawValue) == normalized }) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unknown CMUX extension action scope: \(raw)"
            )
        }
        self = value
    }

    /// Encodes the canonical camel-case scope spelling.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func normalize(_ value: String) -> String {
        value
            .filter { $0 != "_" && $0 != "-" }
            .lowercased()
    }
}

/// Permission families that a process-backed plugin may request.
///
/// A plugin never receives a permission merely because it declares a matching
/// event or action. The host intersects these requests with the user's stored
/// grant before creating a plugin session. The UI-oriented cases are included
/// in the manifest vocabulary so a newer host can report a useful, fail-closed
/// load result even before it implements those surfaces.
public enum CmuxExtensionPluginScope: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    /// Subscribe to lifecycle events over the authenticated control socket.
    case eventHooks
    /// Register commands in the command palette and receive invocations.
    case paletteActions
    /// Contribute a browser/markdown-backed pane.
    case paneContent
    /// Publish status or badge text for a workspace.
    case workspaceBadges

    /// Decodes camel-case, snake-case, or kebab-case scope spellings.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let normalized = Self.normalize(raw)
        guard let value = Self.allCases.first(where: { Self.normalize($0.rawValue) == normalized }) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unknown CMUX plugin scope: \(raw)"
            )
        }
        self = value
    }

    /// Encodes the canonical camel-case scope spelling.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func normalize(_ value: String) -> String {
        value
            .filter { $0 != "_" && $0 != "-" }
            .lowercased()
    }
}

/// Canonical lifecycle events exposed to process-backed plugins.
///
/// Raw values intentionally match the names emitted by the existing cmux
/// event bus. This keeps plugin subscriptions compatible with `events.stream`
/// and avoids a second event transport or a lossy name translation layer.
public enum CmuxExtensionEvent: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    /// A workspace was created.
    case workspaceCreated = "workspace.created"
    /// A workspace was closed.
    case workspaceClosed = "workspace.closed"
    /// A split pane was created.
    case paneCreated = "pane.created"
    /// A split pane was closed.
    case paneClosed = "pane.closed"
    /// A surface was created.
    case surfaceCreated = "surface.created"
    /// A surface was closed.
    case surfaceClosed = "surface.closed"
    /// An agent session started.
    case agentSessionStarted = "agent.session.started"
    /// An agent session changed lifecycle state.
    case agentSessionStateChanged = "agent.session.state_changed"
    /// An agent session ended.
    case agentSessionEnded = "agent.session.ended"
    /// A notification was posted.
    case notificationPosted = "notification.created"
    /// The detected branch for a surface changed.
    case gitBranchChanged = "git.branch.changed"

    /// Decodes canonical names and documented compatibility aliases.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "notification.posted":
            self = .notificationPosted
        case "agent.session.state-changed", "agent.session.stateChanged":
            self = .agentSessionStateChanged
        default:
            let normalized = Self.normalize(raw)
            guard let value = Self.allCases.first(where: { Self.normalize($0.rawValue) == normalized }) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "unknown CMUX plugin lifecycle event: \(raw)"
                )
            }
            self = value
        }
    }

    /// Encodes the canonical event-bus name.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The permission family required to subscribe to this event.
    public var requiredScope: CmuxExtensionPluginScope {
        .eventHooks
    }

    /// The event-bus category used for the canonical event.
    public var category: String {
        switch self {
        case .workspaceCreated, .workspaceClosed:
            return "workspace"
        case .paneCreated, .paneClosed:
            return "pane"
        case .surfaceCreated, .surfaceClosed:
            return "surface"
        case .agentSessionStarted, .agentSessionStateChanged, .agentSessionEnded:
            return "agent"
        case .notificationPosted:
            return "notification"
        case .gitBranchChanged:
            return "git"
        }
    }

    /// All accepted subscription spellings for this event, including legacy
    /// aliases that are normalized to the canonical event-bus name.
    public var acceptedWireNames: Set<String> {
        switch self {
        case .notificationPosted:
            return [rawValue, "notification.posted"]
        case .agentSessionStateChanged:
            return [rawValue, "agent.session.state-changed", "agent.session.stateChanged"]
        default:
            return [rawValue]
        }
    }

    /// Resolves an accepted wire spelling to the canonical event-bus name.
    public static func canonicalName(forWireName name: String) -> String? {
        declaration(forEventName: name)?.rawValue
    }

    private static func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
    }
}

public extension CmuxExtensionEvent {
    /// Returns the event declaration for an event-bus name, if it is part of
    /// the stable plugin contract.
    static func declaration(forEventName name: String) -> Self? {
        if let value = allCases.first(where: { $0.rawValue == name }) {
            return value
        }
        switch name {
        case "notification.posted":
            return .notificationPosted
        case "agent.session.state-changed", "agent.session.stateChanged":
            return .agentSessionStateChanged
        default:
            return nil
        }
    }
}
