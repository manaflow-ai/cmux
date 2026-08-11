enum BackendOnlyRendererFrameReleaseEnqueueResult: Equatable, Sendable {
    case accepted
    case capacityExceeded
    case stopped
}
