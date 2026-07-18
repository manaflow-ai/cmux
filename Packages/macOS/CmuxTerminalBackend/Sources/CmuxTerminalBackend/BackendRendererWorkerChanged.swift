/// Process-lifetime transition for one visible workspace renderer.
public struct BackendRendererWorkerChanged: Decodable, Equatable, Sendable {
    public let workspaceID: WorkspaceID
    public let priorRendererEpoch: UInt64
    public let priorProcessID: UInt32?
    public let rendererEpoch: UInt64?
    public let processID: UInt32?
    public let effectiveUserID: UInt32?
    public let sceneCapabilities: UInt64?
    public let state: BackendRendererWorkerState?
    public let restartCount: UInt64?
    public let retryAfterMilliseconds: UInt64?
    public let reason: String?

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_uuid"
        case priorRendererEpoch = "prior_renderer_epoch"
        case priorProcessID = "prior_process_id"
        case rendererEpoch = "renderer_epoch"
        case processID = "pid"
        case effectiveUserID = "effective_user_id"
        case sceneCapabilities = "scene_capabilities"
        case state
        case restartCount = "restart_count"
        case retryAfterMilliseconds = "retry_after_milliseconds"
        case reason
    }
}
