enum BackendOnlyRendererWorkerWatchResult: Sendable {
    case watching(BackendOnlyRendererWorkerExitFence)
    case alreadyExited
    case unverifiable
}
