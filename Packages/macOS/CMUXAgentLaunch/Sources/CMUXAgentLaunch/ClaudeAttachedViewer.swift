import Foundation

/// The active-session slot a viewer admission displaced, retained so a detach
/// can restore the previous owner without overwriting a newer one.
public struct ClaudeViewerActiveSessionSnapshot: Codable, Equatable, Sendable {
    /// The session that owned the slot before this attachment.
    public let sessionId: String
    /// The owner's turn, when it had one.
    public let turnId: String?
    /// The owner's replacement policy.
    public let allowsNewSessionReplacement: Bool?
    /// The owner's last update time.
    public let updatedAt: TimeInterval

    /// Creates a displaced-slot snapshot.
    public init(
        sessionId: String, turnId: String?,
        allowsNewSessionReplacement: Bool?, updatedAt: TimeInterval
    ) {
        self.sessionId = sessionId
        self.turnId = turnId
        self.allowsNewSessionReplacement = allowsNewSessionReplacement
        self.updatedAt = updatedAt
    }
}

/// An acknowledged native daemon attachment, scoped to one cmux socket and viewer.
public struct ClaudeAttachedViewer: Codable, Equatable, Sendable {
    /// The native daemon's per-connection attachment UUID.
    public let attachmentID: String
    /// The background worker generation that emits hooks.
    public let worker: ClaudeViewerProcessIdentity
    /// The terminal viewer generation that received the attach ACK.
    public let viewer: ClaudeViewerProcessIdentity
    /// The local cmux socket admitting this subscription.
    public let socketPath: String
    /// The workspace owning the viewer at admission.
    public let workspaceID: String
    /// The surface owning the viewer at admission.
    public let surfaceID: String
    /// The admission timestamp used to select the most recent live viewer.
    public let attachedAt: TimeInterval
    /// The surface active-session slot this lease displaced, if any.
    public let displacedSurface: ClaudeViewerActiveSessionSnapshot?
    /// The workspace active-session slot this lease displaced, if any.
    public let displacedWorkspace: ClaudeViewerActiveSessionSnapshot?

    /// Creates an attachment after the CLI validates its local process and pane identities.
    /// - Parameters:
    ///   - attachmentID: A UUID from a successful native daemon handshake.
    ///   - worker: The live registered background worker generation.
    ///   - viewer: The attached terminal's process generation.
    ///   - socketPath: The cmux socket used for admission.
    ///   - workspaceID: The app-resolved workspace UUID.
    ///   - surfaceID: The app-resolved surface UUID.
    ///   - attachedAt: The admission time; defaults to now.
    ///   - displacedSurface: The surface slot this lease replaced.
    ///   - displacedWorkspace: The workspace slot this lease replaced.
    public init(
        attachmentID: String, worker: ClaudeViewerProcessIdentity,
        viewer: ClaudeViewerProcessIdentity, socketPath: String,
        workspaceID: String, surfaceID: String, attachedAt: TimeInterval = Date().timeIntervalSince1970,
        displacedSurface: ClaudeViewerActiveSessionSnapshot? = nil,
        displacedWorkspace: ClaudeViewerActiveSessionSnapshot? = nil
    ) {
        self.attachmentID = attachmentID
        self.worker = worker
        self.viewer = viewer
        self.socketPath = socketPath
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.attachedAt = attachedAt
        self.displacedSurface = displacedSurface
        self.displacedWorkspace = displacedWorkspace
    }

    /// Verifies the worker and viewer generations in the hook's local socket namespace.
    /// - Parameters:
    ///   - workerPID: The actual hook invocation's worker PID.
    ///   - socketPath: The cmux socket receiving the hook.
    /// - Returns: False for dead, recycled, foreign-worker or foreign-socket leases.
    public func admits(workerPID: Int, socketPath: String) -> Bool {
        worker.pid == workerPID && self.socketPath == socketPath
            && worker.isAlive && viewer.isAlive
    }
}
