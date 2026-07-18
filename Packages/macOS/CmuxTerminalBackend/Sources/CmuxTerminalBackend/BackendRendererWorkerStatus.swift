/// Public-kernel process start timestamp paired with a PID across PID reuse.
public struct BackendRendererProcessInstanceToken: Equatable, Hashable, Sendable {
    public let startTimeSeconds: UInt64
    public let startTimeMicroseconds: UInt64

    public init(startTimeSeconds: UInt64, startTimeMicroseconds: UInt64) {
        self.startTimeSeconds = startTimeSeconds
        self.startTimeMicroseconds = startTimeMicroseconds
    }
}

/// Observable process ownership for one visible workspace renderer.
public struct BackendRendererWorkerStatus: Decodable, Equatable, Sendable {
    public let workspaceID: WorkspaceID
    public let rendererEpoch: UInt64
    public let processID: UInt32?
    public let processStartTimeSeconds: UInt64?
    public let processStartTimeMicroseconds: UInt64?
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
        case processStartTimeSeconds = "process_start_time_seconds"
        case processStartTimeMicroseconds = "process_start_time_microseconds"
        case effectiveUserID = "effective_user_id"
        case sceneCapabilities = "scene_capabilities"
        case restartCount = "restart_count"
        case visiblePresentationCount = "visible_presentation_count"
        case state
        case retryAfterMilliseconds = "retry_after_milliseconds"
        case lastError = "last_error"
    }

    public var processInstanceToken: BackendRendererProcessInstanceToken? {
        guard let processStartTimeSeconds, let processStartTimeMicroseconds else { return nil }
        return BackendRendererProcessInstanceToken(
            startTimeSeconds: processStartTimeSeconds,
            startTimeMicroseconds: processStartTimeMicroseconds
        )
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
