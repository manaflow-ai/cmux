public import Foundation

/// Persisted metadata for a managed provider conversation.
public struct ConversationSession: Codable, Hashable, Sendable, Identifiable {
    /// Stable session identity.
    public let id: ConversationID
    /// Provider owning the session.
    public let provider: ConversationProvider
    /// User-visible title.
    public var title: String
    /// Workspace identity supplied by the trusted host.
    public let workspaceID: String
    /// Directory used by the provider process.
    public let directory: String
    /// Provider-native session identity used for resume, when available.
    public var providerSessionID: String?
    /// Selected provider model for future turns.
    public var model: String?
    /// Selected reasoning/effort value for future turns.
    public var effort: String?
    /// Selected response speed value for future turns.
    public var speed: String?
    /// Creation time.
    public let createdAt: Date
    /// Last metadata or event update time.
    public var updatedAt: Date
    /// Provider generation used to reject stale commands and requests.
    public var generation: ConversationGeneration
    /// Current lifecycle state.
    public var state: ConversationSessionState
    /// Whether the task is pinned in the task list.
    public var isPinned: Bool
    /// Whether the task is archived.
    public var isArchived: Bool

    /// Creates session metadata.
    /// - Parameters: See stored properties. `generation` defaults to a newly generated opaque value.
    public init(id: ConversationID, provider: ConversationProvider, title: String, workspaceID: String, directory: String, providerSessionID: String? = nil, model: String? = nil, effort: String? = nil, speed: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date(), generation: ConversationGeneration = UUID().uuidString, state: ConversationSessionState = .starting, isPinned: Bool = false, isArchived: Bool = false) {
        self.id = id; self.provider = provider; self.title = title; self.workspaceID = workspaceID; self.directory = directory; self.providerSessionID = providerSessionID; self.model = model; self.effort = effort; self.speed = speed; self.createdAt = createdAt; self.updatedAt = updatedAt; self.generation = generation; self.state = state; self.isPinned = isPinned; self.isArchived = isArchived
    }
}

/// An idempotent request to create or restore a conversation.
public struct ConversationCreateRequest: Codable, Hashable, Sendable {
    /// Optional command identity used to make retries idempotent.
    public let requestID: ConversationCommandID?
    /// Provider to launch.
    public let provider: ConversationProvider
    /// Trusted workspace identity.
    public let workspaceID: String
    /// Directory resolved by the trusted host.
    public let directory: String
    /// Trusted launch destination.
    public let launchTarget: ConversationLaunchTarget
    /// Optional initial title.
    public let title: String?

    /// Creates a conversation request.
    public init(requestID: ConversationCommandID? = nil, provider: ConversationProvider, workspaceID: String, directory: String, launchTarget: ConversationLaunchTarget, title: String? = nil) {
        self.requestID = requestID; self.provider = provider; self.workspaceID = workspaceID; self.directory = directory; self.launchTarget = launchTarget; self.title = title
    }
}
