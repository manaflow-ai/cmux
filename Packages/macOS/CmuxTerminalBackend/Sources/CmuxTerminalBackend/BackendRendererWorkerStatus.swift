/// Observable process ownership for one visible workspace renderer.
public struct BackendRendererWorkerStatus: Decodable, Equatable, Sendable {
    public let workspaceID: WorkspaceID
    public let rendererEpoch: UInt64
    public let processID: UInt32?
    public let effectiveUserID: UInt32?
    public let sceneCapabilities: UInt64?
    public let restartCount: UInt64
    public let visiblePresentationCount: UInt64
    public let state: BackendRendererWorkerState
    public let retryAfterMilliseconds: UInt64?
    public let lastError: String?

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_uuid"
        case rendererEpoch = "renderer_epoch"
        case processID = "pid"
        case effectiveUserID = "effective_user_id"
        case sceneCapabilities = "scene_capabilities"
        case restartCount = "restart_count"
        case visiblePresentationCount = "visible_presentation_count"
        case state
        case retryAfterMilliseconds = "retry_after_milliseconds"
        case lastError = "last_error"
    }
}

/// Renderer-worker census scoped to one immutable daemon lifetime.
public struct BackendRendererWorkersResponse: Decodable, Equatable, Sendable {
    public let daemonInstanceID: DaemonInstanceID
    public let workers: [BackendRendererWorkerStatus]

    private enum CodingKeys: String, CodingKey {
        case daemonInstanceID = "daemon_instance_id"
        case workers
    }
}
