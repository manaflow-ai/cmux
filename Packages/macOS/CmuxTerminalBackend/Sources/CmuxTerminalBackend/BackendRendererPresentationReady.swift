/// Exact worker-derived font geometry for one renderer presentation lifetime.
public struct BackendRendererPresentationReady: Decodable, Equatable, Sendable {
    public let workspaceID: WorkspaceID
    public let rendererEpoch: UInt64
    public let workerProcessID: UInt32
    public let workerProcessStartTimeSeconds: UInt64
    public let workerProcessStartTimeMicroseconds: UInt64
    public let workerEffectiveUserID: UInt32
    public let terminalID: SurfaceID
    public let terminalEpoch: UInt64
    public let presentationID: PresentationID
    public let presentationGeneration: UInt64
    public let canonicalSequence: UInt64
    public let presentationSequence: UInt64
    public let columns: UInt16
    public let rows: UInt16
    public let cellWidth: UInt32
    public let cellHeight: UInt32
    public let padding: BackendRendererPadding

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_uuid"
        case rendererEpoch = "renderer_epoch"
        case workerProcessID = "worker_pid"
        case workerProcessStartTimeSeconds = "worker_process_start_time_seconds"
        case workerProcessStartTimeMicroseconds = "worker_process_start_time_microseconds"
        case workerEffectiveUserID = "worker_effective_user_id"
        case terminalID = "terminal_id"
        case terminalEpoch = "terminal_epoch"
        case presentationID = "presentation_id"
        case presentationGeneration = "presentation_generation"
        case canonicalSequence = "canonical_sequence"
        case presentationSequence = "presentation_sequence"
        case columns
        case rows
        case cellWidth = "cell_width"
        case cellHeight = "cell_height"
        case padding
    }

    public var workerProcessInstanceToken: BackendRendererProcessInstanceToken {
        BackendRendererProcessInstanceToken(
            startTimeSeconds: workerProcessStartTimeSeconds,
            startTimeMicroseconds: workerProcessStartTimeMicroseconds
        )
    }
}
