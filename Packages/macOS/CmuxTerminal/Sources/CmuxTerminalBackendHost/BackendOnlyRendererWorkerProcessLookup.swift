internal import CmuxTerminalBackend

enum BackendOnlyRendererWorkerProcessLookup {
    case exact(BackendRendererProcessInstanceToken)
    case missing
    case unverifiable
}
