internal import CmuxTerminalRenderCompositor

struct BackendOnlyRetiredFrameIngress: Sendable {
    let receiveTask: Task<Void, Never>?
    let compositorIngress: TerminalRenderCompositorIngress?
    let releaseMetricsBeforeRetirement: BackendOnlyRendererFrameReleaseLaneMetrics
}
