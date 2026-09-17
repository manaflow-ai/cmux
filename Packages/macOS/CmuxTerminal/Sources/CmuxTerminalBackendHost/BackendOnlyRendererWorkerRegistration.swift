internal import Dispatch

struct BackendOnlyRendererWorkerRegistration {
    let source: any DispatchSourceProcess
    let fence: BackendOnlyRendererWorkerExitFence
    let onExit: @Sendable (BackendOnlyRendererWorkerIdentity) -> Void
}
