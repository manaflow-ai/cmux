internal import CmuxTerminalBackend

struct BackendOnlyRendererFrameReleaseEntry: Sendable {
    let release: BackendRendererFrameRelease
    let priority: BackendOnlyRendererFrameReleasePriority
}
