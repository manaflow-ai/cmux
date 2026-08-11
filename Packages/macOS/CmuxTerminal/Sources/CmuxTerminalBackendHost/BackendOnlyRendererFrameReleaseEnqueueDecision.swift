struct BackendOnlyRendererFrameReleaseEnqueueDecision {
    let result: BackendOnlyRendererFrameReleaseEnqueueResult
    var shouldSignal = false
    var failure: BackendOnlyRendererFrameReleaseLaneFailure?
}
