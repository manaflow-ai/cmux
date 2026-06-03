public import Foundation

/// A terminal workspace: a connection to a host plus its panes, status, and backend identity.
public struct TerminalWorkspace: Identifiable, Codable, Equatable, Sendable {
    /// The stable identity type for a workspace.
    public typealias ID = UUID

    /// The workspace identifier.
    public let id: ID
    /// The identifier of the ``TerminalHost`` this workspace connects to.
    public var hostID: TerminalHost.ID
    /// The workspace title.
    public var title: String
    /// The tmux session name used for this workspace.
    public var tmuxSessionName: String
    /// The latest preview text.
    public var preview: String
    /// The timestamp of the last activity in the workspace.
    public var lastActivity: Date
    /// Whether the workspace has unread activity.
    public var unread: Bool
    /// Whether the workspace is pinned.
    public var pinned: Bool
    /// The panes contained in the workspace.
    public var panes: [TerminalPane] = []
    /// The current connection phase.
    public var phase: TerminalConnectionPhase
    /// The most recent connection error message, if any.
    public var lastError: String?
    /// The remote workspace identifier on the backend, if any.
    public var remoteWorkspaceID: String?
    /// The backend identity tying this workspace to a task run, if any.
    public var backendIdentity: TerminalWorkspaceBackendIdentity?
    /// The latest backend-provided metadata, if any.
    public var backendMetadata: TerminalWorkspaceBackendMetadata?
    /// The remote-daemon resume state, if any.
    public var remoteDaemonResumeState: TerminalRemoteDaemonResumeState?

    /// Creates a terminal workspace.
    /// - Parameters:
    ///   - id: The workspace identifier (defaults to a fresh UUID).
    ///   - hostID: The host this workspace connects to.
    ///   - title: The workspace title.
    ///   - tmuxSessionName: The tmux session name.
    ///   - preview: The preview text (defaults to empty).
    ///   - lastActivity: The last-activity timestamp (defaults to now).
    ///   - unread: Whether there is unread activity (defaults to `false`).
    ///   - pinned: Whether the workspace is pinned (defaults to `false`).
    ///   - phase: The connection phase (defaults to `.idle`).
    ///   - lastError: The most recent error message, if any.
    ///   - remoteWorkspaceID: The remote workspace identifier, if any.
    ///   - backendIdentity: The backend identity, if any.
    ///   - backendMetadata: The backend metadata, if any.
    ///   - remoteDaemonResumeState: The remote-daemon resume state, if any.
    public init(
        id: ID = UUID(),
        hostID: TerminalHost.ID,
        title: String,
        tmuxSessionName: String,
        preview: String = "",
        lastActivity: Date = .now,
        unread: Bool = false,
        pinned: Bool = false,
        panes: [TerminalPane] = [],
        phase: TerminalConnectionPhase = .idle,
        lastError: String? = nil,
        remoteWorkspaceID: String? = nil,
        backendIdentity: TerminalWorkspaceBackendIdentity? = nil,
        backendMetadata: TerminalWorkspaceBackendMetadata? = nil,
        remoteDaemonResumeState: TerminalRemoteDaemonResumeState? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.title = title
        self.tmuxSessionName = tmuxSessionName
        self.preview = preview
        self.lastActivity = lastActivity
        self.unread = unread
        self.pinned = pinned
        self.panes = panes
        self.phase = phase
        self.lastError = lastError
        self.remoteWorkspaceID = remoteWorkspaceID
        self.backendIdentity = backendIdentity
        self.backendMetadata = backendMetadata
        self.remoteDaemonResumeState = remoteDaemonResumeState
    }

    /// Whether this workspace is backed by a remote workspace identifier.
    public var isRemoteWorkspace: Bool {
        !(remoteWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// Decodes a workspace, defaulting `pinned` for records that predate the field.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ID.self, forKey: .id)
        hostID = try container.decode(TerminalHost.ID.self, forKey: .hostID)
        title = try container.decode(String.self, forKey: .title)
        tmuxSessionName = try container.decode(String.self, forKey: .tmuxSessionName)
        preview = try container.decode(String.self, forKey: .preview)
        lastActivity = try container.decode(Date.self, forKey: .lastActivity)
        unread = try container.decode(Bool.self, forKey: .unread)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        phase = try container.decode(TerminalConnectionPhase.self, forKey: .phase)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        remoteWorkspaceID = try container.decodeIfPresent(String.self, forKey: .remoteWorkspaceID)
        backendIdentity = try container.decodeIfPresent(TerminalWorkspaceBackendIdentity.self, forKey: .backendIdentity)
        backendMetadata = try container.decodeIfPresent(TerminalWorkspaceBackendMetadata.self, forKey: .backendMetadata)
        remoteDaemonResumeState = try container.decodeIfPresent(TerminalRemoteDaemonResumeState.self, forKey: .remoteDaemonResumeState)
    }
}

extension TerminalWorkspace {
    /// Whether the workspace matches a search query against its and its host's text fields.
    /// - Parameters:
    ///   - query: The already-lowercased search query.
    ///   - host: The host the workspace belongs to.
    /// - Returns: `true` if any searchable field contains `query`.
    public func matches(query: String, host: TerminalHost) -> Bool {
        title.localizedLowercase.contains(query) ||
            preview.localizedLowercase.contains(query) ||
            (backendMetadata?.preview?.localizedLowercase.contains(query) ?? false) ||
            host.name.localizedLowercase.contains(query) ||
            host.hostname.localizedLowercase.contains(query)
    }
}
