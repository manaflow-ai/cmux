struct BackendOnlyRendererFrameReleaseState {
    var queue: BackendOnlyRendererFrameReleaseRingBuffer<BackendOnlyRendererFrameReleaseEntry>
    var accepting = true
    var normalOutstanding = 0
    var recoveryOutstanding = 0
    var idleWaiters: [CheckedContinuation<Void, Never>] = []
    var metrics = BackendOnlyRendererFrameReleaseLaneMetrics(workerStarts: 1)
}
