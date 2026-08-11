enum BackendOnlyRendererFrameReleaseLaneFailure: Equatable, Sendable {
    case capacityExceeded
    case sendFailed
    case stopped
}
